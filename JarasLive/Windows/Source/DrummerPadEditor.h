#pragma once
#include "DrummerPadAssets.h"
#include "FXPresets.h"
#include "VinhetasPanel.h"

namespace catlive {
class DrummerPadEditor final : public Component, public DragAndDropTarget, private Timer {
    struct MenuButton : TextButton {
        std::function<void()> menu;
        void mouseDown(const MouseEvent &e) override {
            if (e.mods.isPopupMenu()) { if (menu) menu(); }
            else TextButton::mouseDown(e);
        }
    };
    struct PerformanceKey final : MenuButton {
        Colour tint;
        bool active = false, assigned = false, target = false, learning = false;
        void paintButton(Graphics &g, bool hover, bool down) override {
            auto face = getLocalBounds().toFloat().reduced(0.5f);
            const auto radius = jmin(5.f, face.getWidth() * 0.065f);
            const bool lit = active || down;
            g.setColour(lit ? tint : Colour(0xff101010));
            g.fillRoundedRectangle(face, radius);
            face.reduce(1.5f, 1.5f);
            ColourGradient rubber(tint.interpolatedWith(Colours::white, lit ? 0.82f : 0.14f), face.getTopLeft(),
                                  tint.interpolatedWith(Colours::black, lit ? 0.f : assigned ? 0.12f : 0.20f),
                                  face.getBottomRight(), false);
            rubber.addColour(0.5, tint);
            g.setGradientFill(rubber);
            g.fillRoundedRectangle(face, radius);
            g.setColour(target ? Colours::white : learning ? Colours::yellow : Colours::white.withAlpha(lit ? 0.90f : hover ? 0.45f : 0.25f));
            g.drawRoundedRectangle(face.reduced(0.6f), radius, (target || learning) ? 2.f : 1.f);
        }
    };
    struct Cell {
        PerformanceKey pad;
        Label legend;
        Slider gain;
        double litUntil = 0;
    };
    static Colour tintFor(int index, int columns) {
        constexpr uint32_t palette[] = {0xffe1d49d, 0xffe9acac, 0xffbeb4ed, 0xff96d9dc,
                                        0xffe3b6cd, 0xffaad9ae, 0xff9ebfe8, 0xffc1a1dc};
        return Colour(palette[(index / columns % 2) * 4 + (index % columns % 4)]);
    }
    AudioEngine &audio;
    ID target;
    String key, kind, selected;
    int count, learning = -1, dragPad = -1;
    std::function<var()> read;
    std::function<void(var)> write;
    std::function<void(String)> report;
    std::vector<std::unique_ptr<Cell>> cells;
    MenuButton preset;
    TextButton browse, previous, next, save;
    Slider master;
    Label level;
    var state;
    std::unique_ptr<FileChooser> audioChooser;
    std::array<uint64_t,48> audioRequests{};
    static inline WeakReference<Component> learner;
public:
    DrummerPadEditor(AudioEngine &engine, ID id, String slot, String type, std::function<var()> getState,
                     std::function<void(var)> putState, std::function<void(String)> error)
        : audio(engine), target(std::move(id)), key(slot), kind(type), count(drummer::count(kind)),
          read(std::move(getState)), write(std::move(putState)), report(std::move(error)), state(drummer::kit(read(), count)) {
        for (auto *b : {&browse, &previous, &next, &save}) addAndMakeVisible(*b);
        browse.setButtonText(String::fromUTF8("☰")); previous.setButtonText(String::fromUTF8("‹")); next.setButtonText(String::fromUTF8("›")); save.setButtonText("+");
        browse.setTooltip("Presets"); save.setTooltip("Save preset");
        preset.setColour(TextButton::buttonColourId, Colour(0xff111111));
        preset.setColour(TextButton::textColourOffId, Colour(0xffb8e3d4));
        addAndMakeVisible(preset); browse.onClick = preset.onClick = [this]{ listPresets(); };
        previous.onClick = [this]{ step(-1); }; next.onClick = [this]{ step(1); };
        save.onClick = [this]{ prompt(-1); }; preset.menu = [this]{ presetMenu(selected); };
        addAndMakeVisible(master); addAndMakeVisible(level);
        level.setText("Volume", dontSendNotification);
        master.setSliderStyle(Slider::LinearHorizontal); master.setTextBoxStyle(Slider::NoTextBox,false,0,0);
        master.setRange(0,1,.001); master.setValue(num(state,"volume",1.),dontSendNotification);
        master.onDragEnd = [this]{ commit(); };
        master.onValueChange = [this]{ put(state,"volume",master.getValue()); preview(); if(!master.isMouseButtonDown())commit(); };
        for (int i=0; i<count; ++i) {
            auto cell = std::make_unique<Cell>();
            auto &b = cell->pad; addAndMakeVisible(b);
            b.setComponentID("drumPad"+String(i+1));
            b.tint = tintFor(i, count == 16 ? 4 : 8);
            addAndMakeVisible(cell->legend);
            cell->legend.setInterceptsMouseClicks(false, false);
            cell->legend.setBorderSize(BorderSize<int>(0));
            cell->legend.setFont(Font(FontOptions(11.f)));
            cell->legend.setJustificationType(Justification::centredLeft);
            cell->legend.setColour(Label::textColourId, Colour(0xffd5d5d5));
            b.onClick = [this,i]{ if(auto v=audio.drummerVoice(target,key)) v->hit(unsigned(i),127); };
            b.menu = [this,i]{ padMenu(i); };
            auto &s = cell->gain; addAndMakeVisible(s);
            s.setSliderStyle(Slider::RotaryHorizontalVerticalDrag); s.setTextBoxStyle(Slider::NoTextBox,false,0,0);
            s.setColour(Slider::rotarySliderFillColourId, b.tint);
            s.setTooltip("Volume"); s.setRange(0,1,.001);
            s.setValue(num(slotAt(i),"volume",1.),dontSendNotification);
            s.onValueChange = [this,i]{ auto pad=slotAt(i); auto &slider=cells[size_t(i)]->gain;
                put(pad,"volume",slider.getValue()); preview(); if(!slider.isMouseButtonDown())commit(); };
            s.onDragEnd = [this]{ commit(); };
            cells.push_back(std::move(cell));
        }
        try { for (const auto &entry:entries()) if(fxpresets::matches(kind,read(),entry))selected=str(entry,"id"); }
        catch(const std::exception &e){report(String::fromUTF8(e.what()));}
        refresh(); startTimerHz(24);
    }
    ~DrummerPadEditor() override { cancelLearning(); }
    void paint(Graphics &g) override {
        const auto body = getLocalBounds().toFloat().reduced(1);
        g.setGradientFill(ColourGradient(Colour(0xff2b2b2b), body.getTopLeft(),
                                         Colour(0xff191919), body.getBottomLeft(), false));
        g.fillRoundedRectangle(body, 9);
        g.setColour(Colours::white.withAlpha(0.12f));
        g.drawRoundedRectangle(body.reduced(0.5f), 9, 1);
        for (float x : {6.f, float(getWidth()) - 6.f}) {
            for (float y : {6.f, float(getHeight()) - 6.f}) {
                g.setColour(Colour(0xff3d3d3d));
                g.fillEllipse(x - 2.3f, y - 2.3f, 4.6f, 4.6f);
                g.setColour(Colour(0xff101010));
                g.drawLine(x - 1.15f, y + 0.9f, x + 1.15f, y - 0.9f);
            }
        }
    }
    void resized() override {
        auto r = getLocalBounds().reduced(16, 11);
        auto top = r.removeFromTop(30); browse.setBounds(top.removeFromLeft(32)); save.setBounds(top.removeFromRight(32));
        const int width = std::min(300,top.getWidth());
        top = top.withSizeKeepingCentre(width,top.getHeight());
        previous.setBounds(top.removeFromLeft(30)); next.setBounds(top.removeFromRight(30)); preset.setBounds(top.reduced(3,0));
        r.removeFromTop(7); auto bottom=r.removeFromBottom(32); level.setBounds(bottom.removeFromLeft(64)); master.setBounds(bottom);
        const int columns = count == 16 ? 4 : 8, rows = count / columns;
        const int knob = count == 16 ? 25 : 19, gap = count == 16 ? 9 : 5, legend = 16;
        constexpr int knobGap = 3;
        r.reduce(4, 3);
        const int side = jmax(1, jmin((r.getWidth() + gap) / columns - gap - knob - knobGap,
                                      (r.getHeight() + gap) / rows - gap - legend));
        const int cellWidth = side + knob + knobGap, cellHeight = side + legend;
        const auto board = r.withSizeKeepingCentre((cellWidth + gap) * columns - gap, (cellHeight + gap) * rows - gap);
        for (int i = 0; i < count; ++i) {
            auto &cell = *cells[size_t(i)];
            const int x = board.getX() + (i % columns) * (cellWidth + gap);
            const int y = board.getY() + (i / columns) * (cellHeight + gap);
            cell.pad.setBounds(x, y, side, side);
            cell.gain.setBounds(x + side + knobGap, y + (side - knob) / 2, knob, knob);
            cell.legend.setBounds(x, y + side, cellWidth, legend);
        }
    }
    bool isInterestedInDragSource(const SourceDetails &d) override { return str(d.description,"type")=="catlive-library-sampler"; }
    void itemDragMove(const SourceDetails &d) override { dragPad=padAt(d.localPosition); refreshCells(); }
    void itemDragExit(const SourceDetails &) override { dragPad=-1; refreshCells(); }
    void itemDropped(const SourceDetails &d) override {
        dragPad=-1;
        const auto i=padAt(d.localPosition); if(i<0)return;
        File file(str(d.description,"file")); const auto path=drummer::reference(file);
        if(path.isEmpty()||!file.existsAsFile())return;
        ++audioRequests[size_t(i)];
        assignAudio(i, path, file.getFileNameWithoutExtension());
    }
private:
    void assignAudio(int i, const String &reference, const String &name) {
        auto pad = slotAt(i);
        put(pad, "sample", reference);
        put(pad, "name", name);
        commit();
        refreshCells();
    }
    static File storeExternalSample(const File &source) {
        const auto folder = VinhetasPanel::padSampleDirectory();
        if (folder.createDirectory().failed()) return {};
        TemporaryFile staged(folder.getChildFile(source.getFileName()));
        if (!source.copyFileTo(staged.getFile())) return {};
        auto destination = folder.getChildFile(source.getFileName());
        for (;;) {
            if (MoveFileW(staged.getFile().getFullPathName().toWideCharPointer(),
                          destination.getFullPathName().toWideCharPointer())) return destination;
            const auto error = GetLastError();
            if (error != ERROR_ALREADY_EXISTS && error != ERROR_FILE_EXISTS) return {};
            if (destination.hasIdenticalContentTo(staged.getFile())) return destination;
            destination = folder.getNonexistentChildFile(source.getFileNameWithoutExtension(), source.getFileExtension());
        }
    }
    void chooseAudio(int i) {
        const auto request = ++audioRequests[size_t(i)];
        audioChooser = std::make_unique<FileChooser>(localization::translate("Insert audio"), File{},
            "*.wav;*.wave;*.aif;*.aiff;*.mp3", true, false, getTopLevelComponent());
        const auto safe = SafePointer<DrummerPadEditor>(this);
        audioChooser->launchAsync(FileBrowserComponent::openMode | FileBrowserComponent::canSelectFiles,
            [safe, i, request](const FileChooser &picker) {
                const auto source = picker.getResult();
                if (!safe || source == File{} || safe->audioRequests[size_t(i)] != request) return;
                static ThreadPool worker(1);
                worker.addJob([safe, i, request, source] {
                    auto error = VinhetasAudio::importError(source);
                    auto reference = drummer::reference(source);
                    const bool external = reference.isEmpty();
                    if (external && error.isEmpty()) {
                        const auto stored = storeExternalSample(source);
                        if (stored == File{}) error = localization::translate("Could not load the pad audio.");
                        else reference = drummer::reference(stored);
                    }
                    MessageManager::callAsync([safe, i, request, source, error, reference, external] {
                        if (external && error.isEmpty()) VinhetasPanel::notifyPadSamplesChanged();
                        if (!safe || safe->audioRequests[size_t(i)] != request) return;
                        if (error.isNotEmpty()) safe->report(error);
                        else safe->assignAudio(i, reference, source.getFileNameWithoutExtension());
                    });
                });
            });
    }
    var slotAt(int i) const { return get(state,"pads")[i]; }
    Array<var> entries() const { fxpresets::Store s; return s.entries(s.read(),"native:"+kind); }
    void commit() { write(state); }
    void preview() { for(int head=0;head<2;++head)if(auto voice=audio.drummerVoice(target,key,head))drummer::configure(*voice,state); }
    int padAt(Point<int> point) const {
        for(int i=0;i<count;++i)if(cells[size_t(i)]->pad.getBounds().getUnion(cells[size_t(i)]->gain.getBounds()).getUnion(cells[size_t(i)]->legend.getBounds()).contains(point))return i;
        return -1;
    }
    void refreshCells() {
        const auto now=Time::getMillisecondCounterHiRes();
        for(int i=0;i<count;++i){
            auto &c=*cells[size_t(i)]; auto name=str(slotAt(i),"name");
            const bool learn = learning == i && learner.get() == this;
            const auto caption = String(i + 1).paddedLeft('0', 2) + "  " + (learn ? String::fromUTF8("Learn MIDI…") : name);
            if (c.legend.getText() != caption) {
                c.legend.setText(caption, dontSendNotification);
                c.pad.setName("Pad " + caption);
            }
            const bool lit = c.litUntil > now, targeted = dragPad == i, assigned = str(slotAt(i), "sample").isNotEmpty();
            if (c.pad.active != lit || c.pad.target != targeted || c.pad.assigned != assigned || c.pad.learning != learn) {
                c.pad.active = lit;
                c.pad.target = targeted;
                c.pad.assigned = assigned;
                c.pad.learning = learn;
                c.pad.repaint();
            }
        }
    }
    void refresh() {
        refreshCells();
        String name="Default";
        try { for(const auto &e:entries())if(str(e,"id")==selected)name=str(e,"name"); }
        catch(const std::exception &e){report(String::fromUTF8(e.what()));}
        preset.setButtonText(name);
    }
    void choose(const var &entry) {
        for (auto &request : audioRequests) ++request;
        selected=str(entry,"id");
        state=drummer::kit(get(entry,"native"),count).clone();commit();
        master.setValue(num(state,"volume",1),dontSendNotification);
        for(int i=0;i<count;++i)cells[size_t(i)]->gain.setValue(num(slotAt(i),"volume",1),dontSendNotification);
        refresh();
    }
    void step(int delta) {
        try { auto all=entries(); all.insert(0,var()); int at=0;
            for(int i=1;i<all.size();++i)if(str(all[i],"id")==selected)at=i;
            choose(all[(at+delta+all.size())%all.size()]);
        } catch(const std::exception &e){report(String::fromUTF8(e.what()));}
    }
    void listPresets() {
        try {
            struct OwnedRows final : Component { ~OwnedRows() override { deleteAllChildren(); } };
            auto rows=std::make_unique<OwnedRows>(); auto all=entries(); all.insert(0,var());
            auto view=std::make_unique<Viewport>();
            for(int i=0;i<all.size();++i) {
                const auto entry=all[i]; auto *row=new MenuButton();
                row->setButtonText(i?str(entry,"name"):"Default");
                row->onClick=[safe=SafePointer<DrummerPadEditor>(this),entry,row]{
                    if(auto *callout=row->findParentComponentOfClass<CallOutBox>())callout->dismiss();
                    if(safe)safe->choose(entry);
                };
                row->menu=[safe=SafePointer<DrummerPadEditor>(this),entry,row]{
                    if(auto *callout=row->findParentComponentOfClass<CallOutBox>())callout->dismiss();
                    if(safe)safe->presetMenu(str(entry,"id"));
                };
                rows->addAndMakeVisible(row); row->setBounds(0,i*28,206,27);
            }
            rows->setSize(206,28*all.size());
            view->setViewedComponent(rows.release(),true); view->setSize(222,std::min(336,28*all.size()));
            CallOutBox::launchAsynchronously(std::move(view),browse.getScreenBounds(),nullptr);
        } catch(const std::exception &e){report(String::fromUTF8(e.what()));}
    }
    void presetMenu(String id) {
        if(id.isEmpty())return;
        PopupMenu menu;menu.addItem(1,"Delete preset");
        menu.showMenuAsync(PopupMenu::Options(),[safe=SafePointer<DrummerPadEditor>(this),id](int action){
            if(!safe||action!=1)return;
            try {fxpresets::Store store;auto library=store.read();auto all=list(get(library,"presets"));
                for(int i=all.size();--i>=0;)if(str(all[i],"id")==id)all.remove(i);
                put(library,"presets",all);
                if(str(get(library,"defaults"),Identifier("native:"+safe->kind))==id)
                    store.setDefault(library,"native:"+safe->kind,{});
                store.write(library);if(safe->selected==id)safe->selected.clear();safe->refresh();
            }catch(const std::exception &e){safe->report(String::fromUTF8(e.what()));}
        });
    }
    void prompt(int i) {
        auto *dialog=new AlertWindow(i<0?"Save preset":"Rename pad","",MessageBoxIconType::NoIcon);
        dialog->addTextEditor("name",i<0?String():str(slotAt(i),"name"),"Name");
        dialog->addButton("Save",1,KeyPress(KeyPress::returnKey));dialog->addButton("Cancel",0,KeyPress(KeyPress::escapeKey));
        dialog->enterModalState(true,ModalCallbackFunction::create([safe=SafePointer<DrummerPadEditor>(this),dialog,i](int picked){
            if(!safe||picked!=1)return;
            const auto name=dialog->getTextEditorContents("name").trim();
            if(i>=0){auto pad=safe->slotAt(i);put(pad,"name",name);safe->commit();safe->refreshCells();return;}
            try {fxpresets::Store store;auto lib=store.read();auto value=safe->read().clone();
                put(value,drummer::field(safe->count),safe->state);
                auto p=fxpresets::capture(safe->kind,value,name);store.save(lib,p);store.write(lib);
                safe->selected=str(p,"id");safe->refresh();
            }catch(const std::exception &e){safe->report(String::fromUTF8(e.what()));}
        }),true);
    }
    void padMenu(int i) {
        PopupMenu menu;menu.addItem(4,localization::translate("Insert audio"));
        menu.addItem(1,"Rename pad");menu.addItem(2,"Learn MIDI");
        const int note=int(num(slotAt(i),"note",-1));if(note>=0)menu.addItem(3,"Unlearn Note "+String(note));
        menu.showMenuAsync(PopupMenu::Options(),[safe=SafePointer<DrummerPadEditor>(this),i](int action){
            if(!safe)return;
            if(action==4)safe->chooseAudio(i);
            if(action==1)safe->prompt(i);
            if(action==2){learner=safe.getComponent();safe->audio.drummerLearnNote=-1;safe->learning=i;}
            if(action==3){auto pad=safe->slotAt(i);pad.getDynamicObject()->removeProperty("note");safe->cancelLearning();safe->commit();}
            safe->refreshCells();
        });
    }
    void cancelLearning(){if(learner.get()==this){learner=nullptr;audio.drummerLearnNote=-2;}learning=-1;}
    void timerCallback() override {
        bool changed = false;
        if(learning>=0&&learner.get()==this&&audio.drummerLearnNote.load()>=0) {
            int note=audio.drummerLearnNote.exchange(-2);
            for(int i=0;i<count;++i){auto pad=slotAt(i);if(int(num(pad,"note",-1))==note)pad.getDynamicObject()->removeProperty("note");}
            auto pad=slotAt(learning);put(pad,"note",note);cancelLearning();commit();changed=true;
        }
        uint64_t mask=0;for(int head=0;head<2;++head)if(auto v=audio.drummerVoice(target,key,head))mask|=v->flashes();
        const auto now=Time::getMillisecondCounterHiRes();
        for (int i=0; i<count; ++i) {
            auto &until = cells[size_t(i)]->litUntil;
            if (mask & (uint64_t(1) << i)) { until = now + 140; changed = true; }
            else if (until > 0 && until <= now) { until = 0; changed = true; }
        }
        if (changed) refreshCells();
    }
};
}
