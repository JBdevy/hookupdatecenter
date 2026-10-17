#pragma once
#include "InstrumentAssets.h"
#include "Localization.h"
namespace catlive {
class EffectInsertPanel final : public Component, private ListBoxModel, private Timer {
  public:
    EffectInsertPanel(File directory, std::function<bool(String, String)> insert,
                      std::function<void()> close, bool allowInstruments = true)
        : projectDirectory(std::move(directory)), apply(std::move(insert)),
          dismiss(std::move(close)), list("Instrument catalog", this) {
        setComponentID("effectInsertPanel");
        addAndMakeVisible(effect);
        effect.addItemList({"EQ", "Compressor", "Pitch", "Delay", "Reverb", "Limiter"}, 1);
        if (allowInstruments) effect.addItem(String::fromUTF8("Instrumentos"), 7);
        effect.addItem("Externo (VST3)", 8);
        effect.setSelectedId(1, dontSendNotification);
        effect.onChange = [this] { selected.clear();refresh();updateLayout(); };
        addAndMakeVisible(browse);browse.onClick=[this]{chooseExternal();};
        const StringArray names{String::fromUTF8("Piano de cauda"),
                                "Piano vertical",
                                String::fromUTF8("Pianos elétricos"),
                                "Teclado",
                                String::fromUTF8("Órgãos"),
                                "Cordas",
                                "Guitarras",
                                "Baixos",
                                "Synth",
                                "Synth Pad",
                                "Lead",
                                "Acordeon",
                                "Metais",
                                "Mallets",
                                "Baterias"};
        for (int i = 0; i < names.size(); ++i) {
            auto *b = categories.add(new TextButton(names[i]));
            addAndMakeVisible(b);
            b->getProperties().set("flat", true);
            b->getProperties().set("fontSize", 11);
            b->setColour(TextButton::buttonColourId, theme::display);
            b->setColour(TextButton::buttonOnColourId, Colour(0xff345a43));
            b->setColour(TextButton::textColourOnId, Colours::white);
            b->onClick = [this, i] {
                category = i;
                refresh();
            };
        }
        addAndMakeVisible(list);
        list.setRowHeight(43);
        list.setColour(ListBox::backgroundColourId, theme::panel);
        list.setOutlineThickness(0);
        addAndMakeVisible(cancel);
        addAndMakeVisible(confirm);
        addAndMakeVisible(status);
        status.setFont(theme::font(10));
        status.setColour(Label::textColourId, theme::yellow);
        cancel.getProperties().set("flat", true);
        cancel.setColour(TextButton::buttonColourId, Colour(0xff505050));
        cancel.onClick = dismiss;
        confirm.getProperties().set("flat", true);
        confirm.setColour(TextButton::buttonColourId, Colour(0xff63b641));
        confirm.onClick = [this] {
            const StringArray kinds{"EQ",     "Compressor", "Pitch",      "Delay",
                                    "Reverb", "Limiter",    "Instruments", "External"};
            if (apply(kinds[effect.getSelectedId() - 1], selected))
                dismiss();
        };
        refresh();
        startTimerHz(8);
    }
    ~EffectInsertPanel() override {
        if (job)
            job->cancel = true;
        if (scan)
            scan->cancel = true;
    }
    void paint(Graphics &g) override {
        g.fillAll(theme::panel);
        g.setColour(Colours::white);
        g.setFont(theme::semiboldFont(14));
        g.drawText("Inserir efeito", 28, catalog() ? 22 : 48, getWidth() - 56, 24,
                   Justification::centredLeft);
        g.setFont(theme::font(13));
        g.drawText("Efeito", 28, catalog() ? 56 : 82, 44, 26, Justification::centredLeft);
    }
    void resized() override {
        effect.setBounds(72, catalog() ? 56 : 82, 230, 26);
        browse.setBounds(28,96,180,28);
        const int cell = (getWidth() - 56) / 4;
        for (int i = 0; i < categories.size(); ++i)
            categories[i]->setBounds(28 + i % 4 * cell, 96 + i / 4 * 33, cell - 5, 28);
        list.setBounds(28, 233, getWidth() - 56, std::max(40, getHeight() - 300));
        if(external())list.setBounds(28,136,getWidth()-56,std::max(40,getHeight()-203));
        const int bottom = getHeight() - (catalog() ? 40 : 58);
        cancel.setBounds(28, bottom, 80, 25);
        confirm.setBounds(getWidth() - 94, bottom, 66, 25);
        status.setBounds(28, getHeight() - 65, getWidth() - 56, 20);
    }
    void updateLayout() {
        const bool show = instruments();
        for (auto *b : categories)
            b->setVisible(show);
        browse.setVisible(external());
        list.setVisible(catalog());
        status.setVisible(catalog());
        setSize(460, catalog() ? 500 : 214);
        if (auto *window = findParentComponentOfClass<DocumentWindow>())
            window->setContentComponentSize(460, catalog() ? 500 : 214);
        resized();
        updateConfirm();
        repaint();
    }

  private:
    struct Download {
        std::atomic<bool> cancel{false};
        std::atomic<int> state{0};
        std::atomic<double> progress{0};
        String error, id;
        File target, temp;
        ~Download() {
            if (temp.existsAsFile())
                temp.deleteFile();
        }
    };
    static ThreadPool &workers() {
        static ThreadPool pool(1);
        return pool;
    }
    File projectDirectory;
    std::function<bool(String, String)> apply;
    std::function<void()> dismiss;
    ComboBox effect;
    OwnedArray<TextButton> categories;
    ListBox list;
    Label status;
    TextButton cancel{"Cancelar"}, confirm{"Aplicar"};
    TextButton browse{"Escolher VST3..."};
    std::unique_ptr<FileChooser> chooser;
    struct Scan {std::atomic<bool> done{false},cancel{false};Array<var> plugins;String error;};
    std::shared_ptr<Scan> scan;
    Array<var> externalItems;
    std::vector<var> items;
    int category = 0;
    String selected;
    std::shared_ptr<Download> job;
    bool instruments() const { return effect.getSelectedId() == 7; }
    bool external() const { return effect.getSelectedId() == 8; }
    bool catalog() const { return instruments()||external(); }
    void chooseExternal() {
        if(scan)return;
        chooser=std::make_unique<FileChooser>("Escolher plugin VST3",File("C:\\Program Files\\Common Files\\VST3"),"*.vst3");
        chooser->launchAsync(FileBrowserComponent::openMode|FileBrowserComponent::canSelectFiles|FileBrowserComponent::canSelectDirectories,
            [safe=SafePointer<EffectInsertPanel>(this)](const FileChooser &dialog){
                if(!safe)return;const auto file=dialog.getResult();if(!file.exists())return;
                if(!file.hasFileExtension("vst3")){safe->status.setText("Escolha um arquivo ou pacote .vst3.",dontSendNotification);return;}
                auto job=std::make_shared<Scan>();safe->scan=job;safe->browse.setEnabled(false);
                safe->status.setText("Verificando plugin...",dontSendNotification);
                workers().addJob([job,file]{
                    auto output=File::getSpecialLocation(File::tempDirectory).getNonexistentChildFile("catlive-vst-scan",".json");
                    try {
                        const auto helper=File::getSpecialLocation(File::currentExecutableFile).getSiblingFile("CatLiveVST3Probe.exe");
                        ChildProcess process;
                        if(!process.start(StringArray{helper.getFullPathName(),file.getFullPathName(),output.getFullPathName(),"--validate"}))throw std::runtime_error("Não foi possível iniciar o scanner VST3.");
                        const auto deadline=Time::getMillisecondCounterHiRes()+90000;
                        bool finished=false;
                        while(!job->cancel&&Time::getMillisecondCounterHiRes()<deadline)
                            if(process.waitForProcessToFinish(100)){finished=true;break;}
                        if(!finished){process.kill();throw std::runtime_error(job->cancel?"Verificação cancelada.":"O plugin excedeu o tempo de verificação.");}
                        auto report=JSON::parse(output.loadFileAsString());
                        if(!flag(report,"success"))throw std::runtime_error(utf8(str(report,"error","O plugin falhou durante a verificação.")));
                        for(auto plugin:catlive::list(get(report,"plugins"))){put(plugin,"path",file.getFullPathName());job->plugins.add(plugin);}
                        if(job->plugins.isEmpty())throw std::runtime_error("Nenhum processador VST3 encontrado.");
                    }catch(const std::exception &e){job->error=String::fromUTF8(e.what());}
                    output.deleteFile();job->done.store(true,std::memory_order_release);
                });
            });
    }
    static String categoryID(int index) {
        const StringArray keys{"pianos",  "upright",  "electric", "keyboard", "organ",
                               "strings", "guitar",   "bass",     "synth",    "synthPad",
                               "lead",    "acordeon", "brass",    "mallets",  "drum"};
        return keys[index];
    }
    void refresh() {
        items.clear();
        if(external()) {for(auto plugin:externalItems)items.push_back(plugin);list.updateContent();list.deselectAllRows();updateConfirm();return;}
        for (auto item : instrumentAssets::catalog())
            if (str(item, "category") == categoryID(category))
                items.push_back(item);
        for (int i = 0; i < categories.size(); ++i)
            categories[i]->setToggleState(i == category, dontSendNotification);
        list.updateContent();
        list.deselectAllRows();
        list.getViewport()->setViewPosition(0, 0);
        updateConfirm();
    }
    void updateConfirm() {
        confirm.setEnabled(
            external()?selected.isNotEmpty():!instruments() ||
            selected.isNotEmpty() &&
                instrumentAssets::resolve(selected, projectDirectory).existsAsFile());
    }
    int getNumRows() override { return (int)items.size(); }
    void paintListBoxItem(int row, Graphics &g, int width, int height, bool) override {
        if (row < 0 || row >= (int)items.size())
            return;
        const auto item = items[(size_t)row];
        if(external()) {
            g.setColour(selected==JSON::toString(item,true)?Colour(0xff294b38):theme::display);g.fillRoundedRectangle(0,1,(float)width,height-5.f,5);
            g.setColour(Colours::white);g.setFont(theme::semiboldFont(12));g.drawText(str(item,"name"),10,2,width-20,20,Justification::centredLeft);
            g.setColour(theme::secondary);g.setFont(theme::font(10));g.drawText(str(item,"vendor")+" · "+str(item,"category"),10,22,width-20,16,Justification::centredLeft);return;
        }
        const auto id = str(item, "id");
        const bool available = instrumentAssets::resolve(id, projectDirectory).existsAsFile(),
                   chosen = id == selected;
        g.setColour(chosen ? Colour(0xff294b38) : theme::display);
        g.fillRoundedRectangle(0, 1, (float)width, height - 5.f, 5);
        g.setColour(available ? Colours::white : theme::secondary);
        g.setFont(theme::semiboldFont(12));
        g.drawFittedText(str(item, "name"), 34, 0, width - 112, height - 4,
                         Justification::centredLeft, 1);
        for (int i = 0; i < 5; ++i) {
            g.setColour(theme::secondary);
            g.fillRect(13 + i * 3, 14, 2, 10);
        }
        if (!available) {
            g.setColour(Colour(0xff505050));
            g.fillRoundedRectangle(width - 72.f, 8, 62, 24, 5);
            g.setColour(Colours::white);
            g.setFont(theme::semiboldFont(11));
            g.drawText(job && job->id == id ? String(job->progress.load() * 100, 0) + "%"
                                            : "Baixar",
                       width - 72, 8, 62, 24, Justification::centred);
        } else if (chosen) {
            g.setColour(theme::green);
            g.setFont(theme::font(16));
            g.drawText(String::fromUTF8("✓"), width - 32, 0, 24, height, Justification::centred);
        }
    }
    void listBoxItemClicked(int row, const MouseEvent &e) override {
        if (row < 0 || row >= (int)items.size())
            return;
        const auto item = items[(size_t)row];
        if(external()){selected=JSON::toString(item,true);list.repaint();updateConfirm();return;}
        const auto id = str(item, "id");
        if (instrumentAssets::resolve(id, projectDirectory).existsAsFile()) {
            selected = id;
            list.repaint();
            updateConfirm();
        } else if (e.x > list.getWidth() - 82)
            download(item);
    }
    void download(var item) {
        if (job && job->state.load() == 0)
            return;
        auto current = std::make_shared<Download>();
        current->id = str(item, "id");
        current->target = instrumentAssets::library().getChildFile(current->id + ".sf2");
        current->target.getParentDirectory().createDirectory();
        current->temp =
            current->target.getSiblingFile(current->id + "-" + text(uuid()) + ".download");
        job = current;
        status.setText(String::fromUTF8("Baixando ") + str(item, "name") + String::fromUTF8("…"),
                       dontSendNotification);
        workers().addJob([current, item] {
            try {
                const auto path = URL::addEscapeChars(str(item, "folder"), true) + "/" +
                                  URL::addEscapeChars(str(item, "name") + ".sf2", true);
                auto stream = std::make_unique<WebInputStream>(
                    URL("https://pub-1b271ca25cc347ce82f835a8125d6d93.r2.dev/" + path), false);
                stream->withConnectionTimeout(5000);
                stream->withNumRedirectsToFollow(3);
                if (!stream->connect(nullptr) || stream->getStatusCode() < 200 ||
                    stream->getStatusCode() >= 300)
                    throw std::runtime_error("Download failed.");
                const auto length = stream->getTotalLength();
                if (length > 512LL * 1024 * 1024)
                    throw std::runtime_error("The instrument exceeds 512 MB.");
                {
                    FileOutputStream output(current->temp);
                    if (!output.openedOk())
                        throw std::runtime_error("Could not save the instrument.");
                    std::array<char, 65536> buffer{};
                    int64 total = 0;
                    while (!stream->isExhausted()) {
                        if (current->cancel.load()) {
                            stream->cancel();
                            throw std::runtime_error("Download cancelled.");
                        }
                        const int count = stream->read(buffer.data(), (int)buffer.size());
                        if (count <= 0)
                            break;
                        total += count;
                        if (total > 512LL * 1024 * 1024 ||
                            !output.write(buffer.data(), (size_t)count))
                            throw std::runtime_error("Could not save the instrument.");
                        current->progress = length > 0 ? total / (double)length : 0;
                    }
                    output.flush();
                    if (output.getStatus().failed() || length >= 0 && total != length ||
                        stream->isError())
                        throw std::runtime_error("Incomplete instrument download.");
                }
                if (!instrumentAssets::validBank(current->temp))
                    throw std::runtime_error("The downloaded file is not an SF2 bank.");
                if (!current->temp.moveFileTo(current->target))
                    throw std::runtime_error("Could not install the instrument.");
                current->progress = 1;
                current->state.store(1, std::memory_order_release);
            } catch (const std::exception &e) {
                current->error = String::fromUTF8(e.what());
                current->state.store(-1, std::memory_order_release);
            }
        });
    }
    void timerCallback() override {
        if(scan&&scan->done.load(std::memory_order_acquire)) {
            externalItems=scan->plugins;status.setText(scan->error,dontSendNotification);scan.reset();browse.setEnabled(true);refresh();
        }
        if (!job)
            return;
        const int state = job->state.load(std::memory_order_acquire);
        if (state) {
            if (state == 1) {
                selected = job->id;
                status.setText(String::fromUTF8("Instrumento pronto."), dontSendNotification);
            } else
                status.setText(job->error, dontSendNotification);
            job.reset();
            updateConfirm();
        }
        list.repaint();
    }
};
} // namespace catlive
