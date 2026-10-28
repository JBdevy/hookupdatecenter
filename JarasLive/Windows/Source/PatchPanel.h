#pragma once
#include "Localization.h"
#include "Session.h"
#include "ModalSheet.h"
#include "Appearance.h"
namespace catlive {
class PatchPanel final : public Component {
  public:
    PatchPanel(Session &s, ID target, std::function<void(String)> report, std::set<ID> selection = {})
        : session(s), id(std::move(target)), error(std::move(report)), targets(std::move(selection)) {
        if (const auto *t = track(); t && (t->role.id == "vinhetas" || t->role.id == "programChange")) targets = {id};
        addAndMakeVisible(viewport);
        viewport.setViewedComponent(&content, false);
        viewport.setScrollBarsShown(true, false); viewport.setScrollBarThickness(4);
        addAndMakeVisible(close);
        close.onClick = [this] {
            if (auto *window = findParentComponentOfClass<DocumentWindow>()) window->closeButtonPressed();
            else ModalSheet::dismiss(*this);
        };
        close.getProperties().set("flat",true);
        close.setColour(TextButton::buttonColourId,Colour(0xff484848));
        build();
    }
    void paint(Graphics &g) override {
        g.setColour(Colour(0xff1f1f1f)); g.fillRoundedRectangle(getLocalBounds().toFloat().reduced(.5f),18);
        g.setColour(Colour(0xff484848)); g.drawRoundedRectangle(getLocalBounds().toFloat().reduced(.5f),18,1);
        g.setColour(Colours::white); g.setFont(theme::semiboldFont(14));
        g.drawText("Patch",28,20,getWidth()-56,24,Justification::centredLeft);
    }
    void mouseDown(const MouseEvent &event) override {
        if (event.y < 46)
            if (auto *window = findParentComponentOfClass<DocumentWindow>())
                dragger.startDraggingComponent(window, event);
    }
    void mouseDrag(const MouseEvent &event) override {
        if (event.getMouseDownPosition().y < 46)
            if (auto *window = findParentComponentOfClass<DocumentWindow>())
                dragger.dragComponent(window, event, nullptr);
    }
    void resized() override {
        viewport.setBounds(28, 46, getWidth() - 56, getHeight() - 104);
        content.setSize(300, height);
        close.setBounds(getWidth() / 2 - 33, getHeight() - 38, 66, 24);
    }

  private:
    Session &session;
    ID id;
    std::function<void(String)> error;
    Viewport viewport;
    ComponentDragger dragger;
    class Content : public Component {
      public:
        std::vector<int> dividers;
        void paint(Graphics &g) override { g.setColour(Colour(0xff454545)); for(int y:dividers)g.fillRect(0,y,getWidth(),1); }
    } content;
    OwnedArray<Component> fields;
    TextButton close{localization::translate("Fechar")};
    int height = 0;
    std::set<ID> targets;
    int batchCategory = 0, batchChoice = 1;
    const jaras::Track *track() const {
        if (auto *song = session.song())
            for (const auto &t : song->tracks)
                if (t.id == id)
                    return &t;
        return nullptr;
    }
    void edit(std::function<void(jaras::Track &)> action, bool routing = true) {
        try {
            session.editTrackSettings([&](jaras::Project &p) {
                for (auto &s : p.songs)
                    for (auto &t : s.tracks)
                        if (t.id == id)
                            action(t);
            }, routing);
        } catch (const std::exception &e) {
            if (error)
                error(String::fromUTF8(e.what()));
        }
        MessageManager::callAsync([safe = SafePointer<PatchPanel>(this)] {
            if (safe)
                safe->build();
        });
    }
    void label(String text, int x, int y, int width, bool bold = false) {
        auto *label = new Label();
        fields.add(label);
        content.addAndMakeVisible(label);
        label->setText(localization::translate(text), dontSendNotification);
        label->setFont(bold ? theme::semiboldFont(12) : theme::font(13));
        label->setBounds(x, y, width, 24);
    }
    ComboBox &choice(int x, int y, int width, const StringArray &items, int selected,
                     std::function<void(int)> changed) {
        auto *box = new ComboBox();
        fields.add(box);
        content.addAndMakeVisible(box);
        box->getProperties().set("preserveNames", true);
        box->addItemList(items, 1);
        box->setSelectedId(selected, dontSendNotification);
        box->setBounds(x, y, width, 26);
        box->onChange = [box, changed] { changed(box->getSelectedId()); };
        return *box;
    }
    void button(String name, int x, int y, int width, std::function<void()> clicked) {
        auto *b = new TextButton(name);
        fields.add(b);
        content.addAndMakeVisible(b);
        b->setBounds(x, y, width, 24);
        b->getProperties().set("flat", true);
        b->onClick = std::move(clicked);
    }
    void buildTimecode(const jaras::Track& t) {
        const auto settings = t.timecode.value_or(jaras::TimecodeSettings{});
        for (int i = 0; i < 2; ++i) {
            auto* mode = new TextButton(i == 0 ? "MTC" : "LTC");
            fields.add(mode); content.addAndMakeVisible(mode);
            mode->setBounds(i * 150, 8, 148, 28);
            mode->setToggleState(settings.mode == (i == 0 ? "mtc" : "ltc"), dontSendNotification);
            mode->onClick = [this, i] { edit([&](auto& track) {
                auto next = track.timecode.value_or(jaras::TimecodeSettings{});
                next.mode = i == 0 ? "mtc" : "ltc"; track.timecode = next;
            }); };
        }
        label(localization::translate("Taxa de quadros"), 0, 48, 140);
        const std::array<double, 4> rates{24, 25, 29.97, 30};
        int selected = 4;
        for (int i = 0; i < 4; ++i) if (rates[(size_t)i] == settings.frameRate) selected = i + 1;
        choice(152, 48, 148, {"24 fps", "25 fps", "29.97 DF", "30 fps"}, selected,
            [this, rates](int index) { edit([&](auto& track) {
                auto next = track.timecode.value_or(jaras::TimecodeSettings{});
                next.frameRate = rates[(size_t)jlimit(0, 3, index - 1)]; track.timecode = next;
            }); });
        auto* relative = new ToggleButton(String::fromUTF8("Iniciar do zero em cada região"));
        fields.add(relative); content.addAndMakeVisible(relative);
        relative->setBounds(0, 88, 300, 26);
        relative->setToggleState(settings.regionRelative, dontSendNotification);
        relative->onClick = [this, relative] { const bool value = relative->getToggleState(); edit([&](auto& track) {
            auto next = track.timecode.value_or(jaras::TimecodeSettings{}); next.regionRelative = value; track.timecode = next;
        }); };
        label("Offset (s)", 0, 126, 140);
        auto* offset = new TextEditor(); fields.add(offset); content.addAndMakeVisible(offset);
        offset->setBounds(220, 126, 80, 26); offset->setFont(theme::font(12));
        offset->setText(String(settings.offset, 3)); offset->setInputRestrictions(18, "0123456789-.,");
        auto saveOffset = [this, offset] {
            const auto value = offset->getText().replaceCharacter(',', '.').trim();
            const double seconds = value.getDoubleValue();
            if (value.isEmpty() || !std::isfinite(seconds)) return;
            edit([&](auto& track) { auto next = track.timecode.value_or(jaras::TimecodeSettings{});
                next.offset = seconds; track.timecode = next; });
        };
        offset->onReturnKey = saveOffset;
        // Rebuilding on focus loss would delete the control being clicked.
        button(localization::translate("Aplicar"), 220, 160, 80, saveOffset);
        if (settings.mode == "mtc") {
            label(String::fromUTF8("Saída MIDI"), 0, 198, 300);
            StringArray names{"Default"}; std::vector<int> ids{0};
            for(int slot=0;slot<6;++slot){names.add("MIDI "+String(slot+1));ids.push_back(TimecodeMIDI::outputSlotID(slot));}
            for (const auto& port : MidiOutput::getAvailableDevices()) {
                names.add(port.name); ids.push_back(TimecodeMIDI::destinationID(port.identifier));
            }
            int selectedPort = 1;
            for (size_t i = 0; i < ids.size(); ++i) if (ids[i] == settings.midiDestination) selectedPort = (int)i + 1;
            if (settings.midiDestination != 0 && selectedPort == 1) {
                names.add(String::fromUTF8("Indisponível")); ids.push_back(settings.midiDestination); selectedPort = (int)ids.size();
            }
            choice(0, 228, 300, names, selectedPort, [this, ids](int n) { edit([&](auto& track) {
                auto next = track.timecode.value_or(jaras::TimecodeSettings{});
                next.midiDestination = ids[(size_t)jlimit(0, (int)ids.size()-1, n-1)]; track.timecode = next;
            }); });
        } else {
            label(String::fromUTF8("Saída de áudio"), 0, 198, 300);
            StringArray names{"Nenhuma"}; std::vector<jaras::OutputPatch> patches{{-1, 2}};
            auto* device = session.audio.devices.getCurrentAudioDevice();
            const int channels = std::max(2, device ? device->getOutputChannelNames().size() : 2);
            for (int i = 1; i <= channels; ++i) { names.add("Out " + String(i)); patches.push_back({i, 1}); }
            for (int i = 1; i < channels; i += 2) { names.add("Out " + String(i) + " / " + String(i+1)); patches.push_back({i, 2}); }
            const auto outputs = t.outputPatches();
            const auto current = outputs.empty() ? jaras::OutputPatch{-1, 2} : outputs.front();
            int selectedOutput = 1;
            for (size_t i = 0; i < patches.size(); ++i)
                if (patches[i].firstChannel == current.firstChannel && patches[i].channelCount == current.channelCount) selectedOutput = (int)i + 1;
            if (current.firstChannel > channels) { names.add(String::fromUTF8("Indisponível · Out ") + String(current.firstChannel));
                patches.push_back(current); selectedOutput = (int)patches.size(); }
            choice(0, 228, 300, names, selectedOutput, [this, patches](int n) { edit([&](auto& track) {
                track.outputs = std::vector<jaras::OutputPatch>{patches[(size_t)jlimit(0, (int)patches.size()-1, n-1)]};
                track.patch.reset(); track.secondaryPatch.reset();
            }); });
        }
        height = 280; resized();
    }
    std::vector<jaras::OutputPatch> masterPatches() const {
        const auto &p = session.project();
        if (p.masterOutputs) return *p.masterOutputs;
        std::vector<jaras::OutputPatch> result{p.masterPatch.value_or(jaras::OutputPatch{1,2})};
        if (p.masterSecondaryPatch) result.push_back(*p.masterSecondaryPatch);
        return result;
    }
    void editMaster(std::function<void(std::vector<jaras::OutputPatch> &)> action) {
        try {
            auto outputs = masterPatches(); action(outputs);
            session.editTrackSettings([&](jaras::Project &p) { p.masterOutputs = outputs; p.masterPatch.reset(); p.masterSecondaryPatch.reset(); }, true);
        } catch (const std::exception &e) { if (error) error(String::fromUTF8(e.what())); }
        MessageManager::callAsync([safe=SafePointer<PatchPanel>(this)]{ if(safe)safe->build(); });
    }
    void buildMaster() {
        auto *device = session.audio.devices.getCurrentAudioDevice();
        label(device ? device->getName() : String::fromUTF8("Áudio não iniciado"),0,8,300);
        label(String::fromUTF8("Saída"),0,44,244,true);
        button("+",264,44,36,[this]{editMaster([](auto &outputs){outputs.push_back({-1,2});});});
        StringArray names{"Nenhum"}; std::vector<jaras::OutputPatch> choices{{-1,2}};
        const int count = device ? device->getOutputChannelNames().size() : 2;
        for(int i=1;i<=count;++i){names.add("Out "+String(i));choices.push_back({i,1});}
        for(int i=1;i<count;i+=2){names.add("Out "+String(i)+" / "+String(i+1));choices.push_back({i,2});}
        const auto outputs=masterPatches();int y=78;
        for(size_t row=0;row<outputs.size();++row){
            int selected=0; for(size_t i=0;i<choices.size();++i) if(choices[i].firstChannel==outputs[row].firstChannel && choices[i].channelCount==outputs[row].channelCount)selected=(int)i+1;
            if(!selected){names.add(String::fromUTF8("Indisponível · Out ")+String(outputs[row].firstChannel));choices.push_back(outputs[row]);selected=(int)choices.size();}
            choice(0,y,244,names,selected,[this,row,choices](int n){if(n>0)editMaster([&](auto &values){if(row<values.size())values[row]=choices[(size_t)n-1];});});
            button(String::fromUTF8("⊖"),264,y,36,[this,row]{editMaster([&](auto &values){if(row<values.size())values.erase(values.begin()+row);});});
            y+=34;
        }
        height=y+16;resized();
    }
    void buildBatch() {
        const auto *song=session.song(); if(!song)return;
        StringArray trackNames; bool allStandard=true,allGrouped=true,outputOnly=false;
        for(const auto &t:song->tracks)if(targets.count(t.id)){trackNames.add(text(t.name));allStandard &= jaras::fixedTrackName(t.role).empty();allGrouped &= t.parentTrackID.has_value();outputOnly |= t.role.id=="vinhetas";}
        label(String::fromUTF8("Patch · Selected tracks"),0,8,300,true);label(trackNames.joinIntoString(", "),0,38,300);
        if(outputOnly)batchCategory=2;
        for(int category=0;category<3;++category){
            if(outputOnly&&category!=2)continue;
            auto *b=new QuietButton(category==0?"Entrada":category==1?"Entrada MIDI":String::fromUTF8("Saída"));fields.add(b);content.addAndMakeVisible(b);
            b->setBounds(category*100,74,98,26);b->setToggleState(batchCategory==category,dontSendNotification);
            b->onClick=[safe=SafePointer<PatchPanel>(this),category]{if(!safe)return;safe->batchCategory=category;safe->batchChoice=1;MessageManager::callAsync([safe]{if(safe)safe->build();});};
        }
        StringArray names{"Nenhum"};std::vector<jaras::OutputPatch> patches{{-1,2}};
        auto *device=session.audio.devices.getCurrentAudioDevice();
        if(batchCategory==1){names.addArray({"MIDI 1","MIDI 2","MIDI 3","MIDI 4","MIDI 5","MIDI 6"});}
        else{
            const int count=device?(batchCategory==0?device->getInputChannelNames().size():device->getOutputChannelNames().size()):(batchCategory==0?0:2);
            if(batchCategory==2 && allStandard){names.add("Master");patches.push_back({0,2});}
            if(batchCategory==2 && allGrouped){names.add("Master Group");patches.push_back({-2,2});}
            for(int i=1;i<=count;++i){names.add(String(batchCategory==0?"In ":"Out ")+String(i));patches.push_back({i,1});}
            for(int i=1;i<count;i+=2){names.add(String(batchCategory==0?"In ":"Out ")+String(i)+" / "+String(i+1));patches.push_back({i,2});}
        }
        choice(0,120,300,names,batchChoice,[this](int n){batchChoice=n;});
        button("Apply to selected tracks",0,164,300,[this,patches]{
            if(batchCategory!=2 && session.audio.isRecording())return;
            try{session.editTrackSettings([&](jaras::Project &p){for(auto &song:p.songs)for(auto &t:song.tracks)if(targets.count(t.id)){
                if(batchCategory!=2&&t.role.id=="vinhetas")continue;
                if(batchCategory==1){if(batchChoice==1)t.midiInput.reset();else t.midiInput=batchChoice-1;}
                else {const auto patch=patches[(size_t)jlimit(0,(int)patches.size()-1,batchChoice-1)];
                    if(batchCategory==0)t.inputPatch=patch;
                    else{t.outputs=std::vector<jaras::OutputPatch>{patch};t.patch.reset();t.secondaryPatch.reset();}
                }
            }}, batchCategory!=1);}catch(const std::exception &e){if(error)error(String::fromUTF8(e.what()));}
        });
        fields.getLast()->setEnabled(batchCategory==2 || (allStandard && !session.audio.isRecording()));
        height=216;resized();
    }
    void build() {
        fields.clear(); content.dividers.clear();
        if(id.empty()){buildMaster();return;}
        if(targets.size()>1){buildBatch();return;}
        const auto *t = track();
        if (!t)
            return;
        if (t->role.id == "programChange") {
            const Appearance preferences;
            const auto inputs=MidiInput::getAvailableDevices(),outputs=MidiOutput::getAvailableDevices();
            StringArray in{localization::translate("All"),localization::translate("None")},out{localization::translate("None")};
            for(int slot=1;slot<=6;++slot) {
                auto input=localization::translate("None"),output=input;
                const auto inID=preferences.value("catlive.midi.slot"+String(slot)).toString();
                const auto outID=preferences.value("catlive.midi.outputSlot"+String(slot)).toString();
                for(const auto &d:inputs)if(d.identifier==inID)input=d.name;
                for(const auto &d:outputs)if(d.identifier==outID)output=d.name;
                in.add("MIDI "+String(slot)+String::fromUTF8(" · ")+input);out.add("MIDI "+String(slot)+String::fromUTF8(" · ")+output);
            }
            label("MIDI input",0,8,92);label("MIDI output",0,52,92);
            choice(96,8,204,in,t->midiInput.value_or(0)+2,[this](int n){session.programChangeScanTrack.clear();edit([&](auto &t){t.midiInput=n==2?std::nullopt:std::optional<int>(n-2);},false);});
            choice(96,52,204,out,t->midiOutput.value_or(0)+1,[this](int n){edit([&](auto &t){t.midiOutput=n>1?std::optional<int>(n-1):std::nullopt;},false);});
            height=94;resized();return;
        }
        if (t->role.id == "timecode") { buildTimecode(*t); return; }
        auto *device = session.audio.devices.getCurrentAudioDevice();
        label(device ? device->getName() : String::fromUTF8("Áudio não iniciado"), 0, 8, 300);
        if(t->role.id!="vinhetas") {
        StringArray inputs{"Nenhum"};
        std::vector<jaras::OutputPatch> inputPatches{{-1, 1}};
        const auto inputNames = device ? device->getInputChannelNames() : StringArray();
        for (int i = 0; i < inputNames.size(); ++i) {
            inputs.add(String(i + 1) + String::fromUTF8(" — ") + inputNames[i]);
            inputPatches.push_back({i + 1, 1});
        }
        for (int i = 0; i + 1 < inputNames.size(); i += 2) {
            inputs.add(String(i + 1) + " / " + String(i + 2) + String::fromUTF8(" — Stereo"));
            inputPatches.push_back({i + 1, 2});
        }
        int selected = 1;
        if (t->inputPatch)
            for (size_t i = 0; i < inputPatches.size(); ++i)
                if (inputPatches[i].firstChannel == t->inputPatch->firstChannel &&
                    inputPatches[i].channelCount == t->inputPatch->channelCount)
                    selected = (int)i + 1;
        if (t->inputPatch && t->inputPatch->firstChannel > 0 && selected == 1) {
            inputs.add(String(t->inputPatch->firstChannel) + String::fromUTF8(" — Indisponível"));
            inputPatches.push_back(*t->inputPatch); selected = int(inputPatches.size());
        }
        label(localization::translate("Entrada"), 0, 44, 62);
        choice(66, 44, 234, inputs, selected, [this, inputPatches](int n) {
            edit([&](auto &t) {
                t.inputPatch = inputPatches[(size_t)jlimit(0,(int)inputPatches.size()-1,n-1)];
            });
        });
        label(localization::translate("Entrada MIDI"), 0, 80, 194);
        label(localization::translate("Canal MIDI"), 208, 80, 92);
        StringArray midi{localization::translate("None")};
        const Appearance preferences; const auto devices = MidiInput::getAvailableDevices();
        for (int slot = 1; slot <= 6; ++slot) {
            const auto identifier = preferences.value("catlive.midi.slot" + String(slot)).toString();
            auto label = localization::translate(identifier.isEmpty() ? "None" : "Unavailable");
            for (const auto &device : devices) if (device.identifier == identifier) label = device.name;
            midi.add("MIDI " + String(slot) + String::fromUTF8(" · ") + label);
        }
        choice(0, 108, 196, midi, t->midiInput.value_or(0)+1, [this](int n) {
            edit([&](auto &t) {
                if (n > 1)
                    t.midiInput = n - 1;
                else
                    t.midiInput.reset();
            }, false);
        });
        StringArray channels{"Todos"};
        for (int i = 1; i <= 16; ++i)
            channels.add(String(i));
        choice(208, 108, 92, channels, t->midiChannel.value_or(0) + 1,
               [this](int n) { edit([&](auto &t) { if(n>1)t.midiChannel=n-1;else t.midiChannel.reset(); }, false); });
        }
        const int outputTop=t->role.id=="vinhetas"?44:148;
        auto outputs = t->outputPatches();
        label(String::fromUTF8("Saída"), 0, outputTop, 200, true);
        button("+", 264, outputTop, 36, [this] {
            edit([](auto &t) {
                auto outputs = t.outputPatches();
                outputs.push_back({0, 2});
                t.outputs = outputs;
                t.patch.reset();
                t.secondaryPatch.reset();
            });
        });
        StringArray destinations{"Master", "Nenhum"};
        std::vector<jaras::OutputPatch> patches{{0, 2}, {-1, 2}};
        if (t->parentTrackID) {
            destinations.add("Master Group");
            patches.push_back({-2, 2});
        }
        const int outputCount = std::max(2, device ? device->getOutputChannelNames().size() : 2);
        for (int i = 1; i <= outputCount; ++i) {
            destinations.add("Out " + String(i));
            patches.push_back({i, 1});
        }
        for (int i = 1; i < outputCount; i += 2) {
            destinations.add("Out " + String(i) + " / " + String(i + 1));
            patches.push_back({i, 2});
        }
        int y = outputTop+34;
        for (size_t row = 0; row < outputs.size(); ++row) {
            const auto patch = outputs[row];
            int selected = 0;
            for (size_t p = 0; p < patches.size(); ++p)
                if (patch.firstChannel == patches[p].firstChannel &&
                    patch.channelCount == patches[p].channelCount)
                    selected = (int)p + 1;
            if (selected == 0) {
                destinations.add(String(patch.firstChannel) + " / " +
                                 String(patch.firstChannel + patch.channelCount - 1) +
                                 String::fromUTF8(" — Indisponível"));
                patches.push_back(patch);
                selected = (int)patches.size();
            }
            choice(0, y, 244, destinations, selected, [this, row, patches](int n) {
                edit([&](auto &t) {
                    auto outputs = t.outputPatches();
                    if (row < outputs.size())
                        outputs[row] = patches[(size_t)n - 1];
                    t.outputs = outputs;
                    t.patch.reset();
                    t.secondaryPatch.reset();
                });
            });
            button(String::fromUTF8("⊖"), 264, y, 36, [this, row] {
                edit([&](auto &t) {
                    auto outputs = t.outputPatches();
                    if (row < outputs.size())
                        outputs.erase(outputs.begin() + row);
                    t.outputs = outputs;
                    t.patch.reset();
                    t.secondaryPatch.reset();
                });
            });
            y += 34;
        }
        if (jaras::fixedTrackName(t->role).empty() && t->role.id!="vinhetas")
            for (bool receive : {true, false}) {
                content.dividers.push_back(y + 4);
                y += 16;
                label(receive ? "Recebimento" : "Envio", 0, y, 244, true);
                button("+", 264, y, 36, [this, receive] {
                    edit([&](auto &t) {
                        if (!t.routing)
                            t.routing = jaras::TrackRouting{{}, {}};
                        auto &routes = receive ? t.routing->receives : t.routing->transmitters;
                        routes.push_back({});
                    });
                });
                y += 34;
                const auto routes =
                    t->routing ? (receive ? t->routing->receives : t->routing->transmitters)
                               : std::vector<std::optional<ID>>();
                StringArray names{"Nenhum"};
                std::vector<ID> ids{ID{}};
                if (auto *song = session.song())
                    for (const auto &other : song->tracks)
                        if (other.id != id && jaras::fixedTrackName(other.role).empty()) {
                            names.add(text(other.name));
                            ids.push_back(other.id);
                        }
                for (size_t row = 0; row < routes.size(); ++row) {
                    int selected = 1;
                    for (size_t i = 1; i < ids.size(); ++i)
                        if (routes[row] && *routes[row] == ids[i])
                            selected = (int)i + 1;
                    choice(0, y, 244, names, selected, [this, receive, row, ids](int n) {
                        edit([&](auto &t) {
                            if (!t.routing)
                                return;
                            auto &routes = receive ? t.routing->receives : t.routing->transmitters;
                            if (row < routes.size())
                                routes[row] =
                                    n > 1 ? std::optional<ID>(ids[(size_t)n - 1]) : std::nullopt;
                        });
                    });
                    button(String::fromUTF8("⊖"), 264, y, 36, [this, receive, row] {
                        edit([&](auto &t) {
                            if (!t.routing)
                                return;
                            auto &routes = receive ? t.routing->receives : t.routing->transmitters;
                            if (row < routes.size())
                                routes.erase(routes.begin() + row);
                        });
                    });
                    y += 34;
                }
            }
        height = y + 16;
        resized();
    }
};
} // namespace catlive
