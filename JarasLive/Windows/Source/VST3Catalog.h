#pragma once
#include "Common.h"
namespace catlive {
// Scanning runs in a replaceable helper process; plugin code never runs on the UI thread.
class VST3Catalog final {
  public:
    static VST3Catalog &shared() { static VST3Catalog value; return value; }
    StringArray paths;
    Array<var> plugins;
    String status;
    bool scanning = false;
    uint64 revision = 0;
    void addPath(const File &folder) {
        if (scanning || !folder.isDirectory()) return;
        for (const auto &path : paths) if (File(path) == folder) return;
        paths.add(folder.getFullPathName()); save(); ++revision; scan();
    }
    void removePath(const String &path) {
        if (scanning) return;
        paths.removeString(path);
        for (int i=plugins.size();--i>=0;) {
            const File pluginFile(str(plugins[i],"path"));
            bool included = false;
            for (const auto &root : paths) included |= pluginFile == File(root) || pluginFile.isAChildOf(File(root));
            if (!included) plugins.remove(i);
        }
        save(); ++revision;
    }
    void scan() {
        if (scanning) return;
        scanning = true; status = String::fromUTF8("Escaneando plugins…"); ++revision;
        auto roots = paths; auto weak = std::weak_ptr<int>(alive);
        worker.addJob([this, roots, weak] {
            Array<var> found; StringArray failures; std::set<String> seen;
            std::function<void(File)> visit = [&](File folder) {
                if (stopping.load()) return;
                if (folder.hasFileExtension("vst3")) {
                    const auto path = folder.getFullPathName();
                    if (!seen.insert(path.toLowerCase()).second) return;
                    auto output = File::getSpecialLocation(File::tempDirectory).getNonexistentChildFile("catlive-vst3", ".json");
                    try {
                        ChildProcess process;
                        const auto helper = File::getSpecialLocation(File::currentExecutableFile).getSiblingFile("CatLiveVST3Probe.exe");
                        if (!process.start(StringArray{helper.getFullPathName(),path,output.getFullPathName(),"--validate"})) throw std::runtime_error("Falha ao iniciar o scanner.");
                        const auto until = Time::getMillisecondCounterHiRes() + 20000;
                        while (process.isRunning() && !stopping.load() && Time::getMillisecondCounterHiRes() < until) Thread::sleep(25);
                        if (process.isRunning()) { process.kill(); throw std::runtime_error("Tempo de verificação excedido."); }
                        const auto result = JSON::parse(output);
                        if (!flag(result,"success")) throw std::runtime_error(utf8(str(result,"error","Falha ao verificar plugin.")));
                        for (auto plugin : list(get(result,"plugins"))) { put(plugin,"path",path); found.add(plugin); }
                    } catch (const std::exception &e) { failures.add(folder.getFileName() + ": " + String::fromUTF8(e.what())); }
                    output.deleteFile(); return;
                }
                if (folder.isSymbolicLink() || !folder.isDirectory()) return;
                for (const auto &entry : folder.findChildFiles(File::findFilesAndDirectories,false)) visit(entry);
            };
            for (const auto &path : roots) visit(File(path));
            MessageManager::callAsync([this, weak, found, failures] {
                if (weak.expired()) return;
                plugins = found; scanning = false;
                status = String(plugins.size()) + " plugins encontrados" + (failures.isEmpty() ? "." : "; " + String(failures.size()) + " falha(s). " + failures.joinIntoString("\n"));
                ++revision; save();
            });
        });
    }
  private:
    File file = File::getSpecialLocation(File::userApplicationDataDirectory).getChildFile("Hook Developer/CatLive/vst3-catalog.json");
    ThreadPool worker{1};
    std::shared_ptr<int> alive = std::make_shared<int>(0);
    std::atomic<bool> stopping{false};
    VST3Catalog() {
        const auto saved = JSON::parse(file);
        if (get(saved,"paths").isArray()) for (const auto &path : list(get(saved,"paths"))) paths.add(path.toString());
        else { paths.add("C:\\Program Files\\Common Files\\VST3");
            paths.add(File::getSpecialLocation(File::windowsLocalAppData).getChildFile("Programs/Common/VST3").getFullPathName()); }
        plugins = list(get(saved,"plugins"));
    }
    ~VST3Catalog() { stopping = true; alive.reset(); worker.removeAllJobs(true,25000); }
    void save() {
        auto saved = object(); Array<var> values; for (const auto &path : paths) values.add(path);
        put(saved,"paths",values); put(saved,"plugins",plugins);
        file.getParentDirectory().createDirectory();
        if (!file.replaceWithText(JSON::toString(saved))) status = String::fromUTF8("Não foi possível salvar o catálogo de plugins.");
    }
};
class ExternalPluginBrowser final : public Component, private ListBoxModel, private Timer {
  public:
    ExternalPluginBrowser(std::function<void(var)> choose, std::function<void()> close, bool allowInstruments = true)
        : picked(std::move(choose)), dismiss(std::move(close)), list("Plugins VST3",this), instrumentsAllowed(allowInstruments) {
        addAndMakeVisible(search); search.setFont(theme::font(13)); search.setTextToShowWhenEmpty("Buscar plugins",theme::secondary); search.setPopupMenuEnabled(false);
        search.onTextChange = [this] { refresh(); };
        addAndMakeVisible(list); list.setRowHeight(96); list.setColour(ListBox::backgroundColourId,theme::panel); list.setOutlineThickness(0);
        addAndMakeVisible(scan); scan.onClick=[] { VST3Catalog::shared().scan(); }; scan.getProperties().set("flat",true);
        addAndMakeVisible(cancel); cancel.onClick=dismiss; cancel.getProperties().set("flat",true);
        addAndMakeVisible(message); message.setFont(theme::font(11)); message.setColour(Label::textColourId,theme::secondary);
        refresh(); startTimerHz(4);
    }
    void paint(Graphics &g) override { g.fillAll(theme::panel); }
    void resized() override {
        search.setBounds(20,16,getWidth()-40,30); list.setBounds(16,58,getWidth()-32,getHeight()-124);
        scan.setBounds(20,getHeight()-46,150,28); cancel.setBounds(getWidth()-110,getHeight()-46,90,28);
        message.setBounds(182,getHeight()-46,std::max(20,getWidth()-306),28);
    }
  private:
    std::function<void(var)> picked; std::function<void()> dismiss;
    TextEditor search; ListBox list; TextButton scan{"Escanear plugins"},cancel{"Fechar"}; Label message;
    Array<var> matches; String selected; uint64 revision = ~uint64(0);
    bool instrumentsAllowed = true;
    void refresh() {
        auto &catalog = VST3Catalog::shared(); matches.clear();
        const auto query=search.getText().trim();
        for (auto plugin : catalog.plugins) {
            if (!instrumentsAllowed && str(plugin,"category").containsIgnoreCase("Instrument")) continue;
            if(query.isEmpty() || (str(plugin,"name")+" "+str(plugin,"vendor")+" "+str(plugin,"category")).containsIgnoreCase(query)) matches.add(plugin);
        }
        list.updateContent(); list.repaint();
        message.setText(catalog.scanning ? catalog.status : String(matches.size()) + " plugins",dontSendNotification);
        scan.setEnabled(!catalog.scanning); revision=catalog.revision;
    }
    void timerCallback() override { if(revision!=VST3Catalog::shared().revision)refresh(); }
    int getNumRows() override { return (matches.size()+3)/4; }
    void paintListBoxItem(int row,Graphics &g,int width,int,bool) override {
        const int cell=width/4;
        for(int col=0;col<4;++col) {
            const int index=row*4+col;if(index>=matches.size())break;const auto &p=matches[index];
            const auto id=str(p,"classID")+str(p,"path");const auto bounds=juce::Rectangle<float>((float)(col*cell+4),4,(float)(cell-8),88);
            g.setColour(selected==id?theme::green.withAlpha(.16f):theme::display);g.fillRoundedRectangle(bounds,6);
            g.setColour(selected==id?theme::green:theme::line);g.drawRoundedRectangle(bounds,6,1);
            g.setColour(Colours::white);g.setFont(theme::font(12,true));g.drawFittedText(str(p,"name"),bounds.reduced(10).withHeight(40).toNearestInt(),Justification::topLeft,2);
            g.setColour(theme::secondary);g.setFont(theme::font(10));g.drawText(str(p,"vendor"),bounds.reduced(10).withTrimmedTop(46),Justification::topLeft,true);
        }
    }
    void listBoxItemClicked(int row,const MouseEvent &event) override {
        if(!event.mods.isLeftButtonDown())return;
        const int width=std::max(1,list.getWidth()-list.getVerticalScrollBar().getWidth());
        const int index=row*4+jlimit(0,3,event.x/(std::max(1,width/4)));
        if(index>=matches.size())return;const auto plugin=matches[index];selected=str(plugin,"classID")+str(plugin,"path");list.repaint();picked(plugin);
    }
};
}
