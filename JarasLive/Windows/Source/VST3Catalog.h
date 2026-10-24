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
    double scanProgress = -1.0;
    String currentPlugin;
    int completedPlugins = 0, totalPlugins = 0;
    String progressText() const {
        if (totalPlugins == 0) return String::fromUTF8("Localizando plugins…");
        return String(completedPlugins) + " / " + String(totalPlugins) + " — " + currentPlugin;
    }
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
    // Metadata covers the entire bundle, so replacing the executable or resources
    // invalidates a cached scan without loading third-party code again.
    static String fingerprint(const File &module) {
        if (!module.exists()) return {};
        Array<File> files{module};
        if (module.isDirectory()) files.addArray(module.findChildFiles(File::findFilesAndDirectories,true));
        std::vector<String> entries;
        for (const auto &entry : files) entries.push_back(entry.getRelativePathFrom(module)+"|"+String(entry.getSize())+"|"+String(entry.getLastModificationTime().toMilliseconds()));
        std::sort(entries.begin(),entries.end()); String metadata="v1\n";
        for (const auto &entry : entries) metadata+=entry+"\n";
        return SHA256(metadata.toRawUTF8(),(size_t)metadata.getNumBytesAsUTF8()).toHexString();
    }
    void cancelScan() { cancelRequested = true; }
    static constexpr int pluginTimeoutMilliseconds = 120000;
    bool hasFailedPlugins() const {
        for (const auto &entry : cache) if (str(entry.second,"error").isNotEmpty()) return true;
        return false;
    }
    void scan(bool retryFailed = false) {
        if (scanning) return;
        cancelRequested = false; scanning = true; status = String::fromUTF8("Escaneando plugins…");
        scanProgress = -1.0; currentPlugin.clear(); completedPlugins = totalPlugins = 0; ++revision;
        auto roots = paths; auto previousCache = cache; auto previousPlugins = plugins; auto weak = std::weak_ptr<int>(alive);
        worker.addJob([this, roots, previousCache, previousPlugins, weak, retryFailed] {
            Array<var> found; StringArray failures; std::set<String> seen;
            Array<File> candidates;
            std::function<void(File)> visit = [&](File folder) {
                if (stopping.load() || cancelRequested.load()) return;
                if (folder.hasFileExtension("vst3")) {
                    if (seen.insert(folder.getFullPathName().toLowerCase()).second) candidates.add(folder);
                    return;
                }
                if (folder.isSymbolicLink() || !folder.isDirectory()) return;
                for (const auto &entry : folder.findChildFiles(File::findFilesAndDirectories,false)) visit(entry);
            };
            for (const auto &path : roots) visit(File(path));
            auto report = [this, weak, total=candidates.size()](int completed, String name) {
                MessageManager::callAsync([this, weak, total, completed, name] {
                    if (weak.expired()) return;
                    totalPlugins = total; completedPlugins = completed; currentPlugin = name;
                    scanProgress = total > 0 ? double(completed) / total : 1.0;
                });
            };
            int completed = 0;
            for (const auto &folder : candidates) {
                    if (stopping.load() || cancelRequested.load()) break;
                    const auto path = folder.getFullPathName();
                    report(completed, folder.getFileNameWithoutExtension());
                    const auto stamp = fingerprint(folder);
                    const auto cached = previousCache.find(path.toLowerCase());
                    if (stamp.isNotEmpty() && cached != previousCache.end() && str(cached->second,"fingerprint") == stamp) {
                        const auto error = str(cached->second,"error");
                        if (error.isEmpty() || !retryFailed) {
                            if (error.isNotEmpty()) failures.add(folder.getFileName() + ": " + error);
                            else found.addArray(list(get(cached->second,"plugins")));
                            report(++completed, folder.getFileNameWithoutExtension());
                            continue;
                        }
                    }
                    // Upgrade the previous successful catalog without running its plugins again.
                    // Future scans compare the installed bundle against this initial baseline.
                    if (stamp.isNotEmpty() && cached == previousCache.end()) {
                        Array<var> known;
                        for (const auto &plugin : previousPlugins) if (str(plugin,"path").equalsIgnoreCase(path)) known.add(plugin);
                        if (!known.isEmpty()) {
                            found.addArray(known);
                            auto record=object();put(record,"path",path);put(record,"fingerprint",stamp);put(record,"plugins",known);
                            MessageManager::callAsync([this,weak,path,record]{if(!weak.expired()){cache[path.toLowerCase()]=record;save();}});
                            report(++completed,folder.getFileNameWithoutExtension());continue;
                        }
                    }
                    auto output = File::getSpecialLocation(File::tempDirectory).getNonexistentChildFile("catlive-vst3", ".json");
                    try {
                        ChildProcess process;
                        const auto helper = File::getSpecialLocation(File::currentExecutableFile).getSiblingFile("CatLiveVST3Probe.exe");
                        // Discover every audio class, as the macOS catalog does.
                        // A shell can contain mono, stereo and surround plugins;
                        // instantiating only its first class rejects unrelated
                        // valid classes. Audio/state validation belongs to loading
                        // the selected class (and the explicit --validate test).
                        const auto command = probeCommand ? probeCommand(folder, output) : StringArray{helper.getFullPathName(),path,output.getFullPathName(),"--scan"};
                        if (!process.start(command, 0)) throw std::runtime_error("Falha ao iniciar o scanner.");
                        const auto deadline = Time::getMillisecondCounterHiRes() + probeTimeoutMilliseconds;
                        while (process.isRunning() && !stopping.load() && !cancelRequested.load()
                               && Time::getMillisecondCounterHiRes() < deadline) Thread::sleep(25);
                        if (stopping.load() || cancelRequested.load()) { if (process.isRunning()) process.kill(); output.deleteFile(); break; }
                        if (process.isRunning()) {
                            process.kill(); process.waitForProcessToFinish(1000);
                            throw std::runtime_error("Plugin sem resposta por 2 minutos; ignorado.");
                        }
                        const auto result = JSON::parse(output);
                        if (process.getExitCode()!=0 || !flag(result,"success")) throw std::runtime_error(utf8(str(result,"error","Falha ao verificar plugin.")));
                        Array<var> verified;
                        for (auto plugin : list(get(result,"plugins"))) { put(plugin,"path",path); verified.add(plugin); found.add(plugin); }
                        if (stamp.isNotEmpty() && fingerprint(folder) == stamp) {
                            auto record=object(); put(record,"path",path); put(record,"fingerprint",stamp); put(record,"plugins",verified);
                            MessageManager::callAsync([this,weak,path,record] {
                                if (weak.expired()) return;
                                cache[path.toLowerCase()]=record; save();
                            });
                        }
                    } catch (const std::exception &e) {
                        const auto error = String::fromUTF8(e.what());
                        failures.add(folder.getFileName() + ": " + error);
                        // Never quarantine a user cancellation or a bundle replaced during its scan.
                        if (!stopping.load() && !cancelRequested.load() && stamp.isNotEmpty() && fingerprint(folder) == stamp) {
                            auto record=object(); put(record,"path",path); put(record,"fingerprint",stamp);
                            put(record,"plugins",Array<var>{}); put(record,"error",error);
                            MessageManager::callAsync([this,weak,path,record] {
                                if (!weak.expired()) { cache[path.toLowerCase()]=record; save(); }
                            });
                        }
                    }
                    output.deleteFile();
                    report(++completed, folder.getFileNameWithoutExtension());
            }
            const bool cancelled=cancelRequested.load() || stopping.load();
            MessageManager::callAsync([this, weak, found, failures, cancelled] {
                if (weak.expired()) return;
                if (cancelled) {
                    for (const auto &plugin : found) {
                        for (int i=plugins.size(); --i>=0;) if (str(plugins[i],"path")==str(plugin,"path") && str(plugins[i],"classID")==str(plugin,"classID")) plugins.remove(i);
                        plugins.add(plugin);
                    }
                } else { plugins = found; scanProgress = 1.0; }
                scanning = false; currentPlugin.clear();
                status = cancelled ? String::fromUTF8("Escaneamento cancelado.") : String(plugins.size()) + " plugins encontrados" + (failures.isEmpty() ? "." : "; " + String(failures.size()) + " falha(s). " + failures.joinIntoString("\n"));
                ++revision; save();
            });
        });
    }
  private:
    File file;
    ThreadPool worker{1};
    std::shared_ptr<int> alive = std::make_shared<int>(0);
    std::atomic<bool> stopping{false}, cancelRequested{false};
    std::map<String,var> cache;
    VST3Catalog() : VST3Catalog(File::getSpecialLocation(File::userApplicationDataDirectory).getChildFile("Hook Developer/CatLive/vst3-catalog.json")) {}
  public:
    using ProbeCommand = std::function<StringArray(const File &, const File &)>;
    explicit VST3Catalog(File storage, ProbeCommand command = {}, int timeoutMilliseconds = pluginTimeoutMilliseconds)
        : file(std::move(storage)), probeCommand(std::move(command)), probeTimeoutMilliseconds(std::max(1,timeoutMilliseconds)) {
        const auto saved = JSON::parse(file);
        if (get(saved,"paths").isArray()) for (const auto &path : list(get(saved,"paths"))) paths.add(path.toString());
        else { paths.add("C:\\Program Files\\Common Files\\VST3");
            paths.add(File::getSpecialLocation(File::windowsLocalAppData).getChildFile("Programs/Common/VST3").getFullPathName()); }
        plugins = list(get(saved,"plugins"));
        for (const auto &record : list(get(saved,"scanCache")))
            if (get(record,"plugins").isArray() && str(record,"fingerprint").isNotEmpty()) cache[str(record,"path").toLowerCase()]=record;
    }
    ~VST3Catalog() { stopping = true; alive.reset(); worker.removeAllJobs(true,25000); }
  private:
    ProbeCommand probeCommand;
    const int probeTimeoutMilliseconds;
    void save() {
        auto saved = object(); Array<var> values; for (const auto &path : paths) values.add(path);
        put(saved,"paths",values); put(saved,"plugins",plugins);
        Array<var> records; for (const auto &entry : cache) records.add(entry.second); put(saved,"scanCache",records);
        file.getParentDirectory().createDirectory();
        if (!file.replaceWithText(JSON::toString(saved))) status = String::fromUTF8("Não foi possível salvar o catálogo de plugins.");
    }
};
inline StringArray pluginTypes(const var &plugin) {
    auto types=StringArray::fromTokens(str(plugin,"category"),"|",""); types.trim(); types.removeEmptyStrings();
    if (types.isEmpty()) types.add("Uncategorized"); return types;
}
inline bool pluginMatches(const var &plugin,const String &query,const String &type,const String &vendor,bool instrumentsAllowed) {
    if (!instrumentsAllowed && str(plugin,"category").containsIgnoreCase("Instrument")) return false;
    if (query.trim().isNotEmpty()) return (str(plugin,"name")+" "+str(plugin,"vendor")+" "+str(plugin,"category")).containsIgnoreCase(query.trim());
    return (type.isEmpty() || pluginTypes(plugin).contains(type)) && (vendor.isEmpty() || str(plugin,"vendor")==vendor);
}
class ExternalPluginBrowser final : public Component, private ListBoxModel, private Timer {
  public:
    ExternalPluginBrowser(std::function<void(var)> choose, std::function<void()> close, bool allowInstruments = true)
        : picked(std::move(choose)), dismiss(std::move(close)), list("Plugins VST3",this), instrumentsAllowed(allowInstruments) {
        addAndMakeVisible(typeFilter); addAndMakeVisible(vendorFilter);
        typeFilter.setComponentID("pluginTypeFilter"); vendorFilter.setComponentID("pluginVendorFilter");
        typeFilter.setTooltip("Tipo"); vendorFilter.setTooltip("Empresa");
        typeFilter.onChange=[this] { refresh(); }; vendorFilter.onChange=[this] { refresh(); };
        addAndMakeVisible(typeLabel); typeLabel.setText("Tipo",dontSendNotification);
        addAndMakeVisible(vendorLabel); vendorLabel.setText("Empresa",dontSendNotification);
        addAndMakeVisible(search); search.setFont(theme::font(13)); search.setTextToShowWhenEmpty("Buscar plugins",theme::secondary); search.setPopupMenuEnabled(false);
        search.onTextChange = [this] { refresh(); };
        addAndMakeVisible(list); list.setComponentID("externalPluginList"); list.setRowHeight(64); list.setColour(ListBox::backgroundColourId,theme::panel); list.setOutlineThickness(0);
        addAndMakeVisible(scan); scan.onClick=[] { auto &catalog=VST3Catalog::shared(); if(catalog.scanning)catalog.cancelScan();else catalog.scan(); }; scan.getProperties().set("flat",true);
        addAndMakeVisible(retry); retry.onClick=[] { VST3Catalog::shared().scan(true); }; retry.getProperties().set("flat",true);
        addAndMakeVisible(cancel); cancel.onClick=dismiss; cancel.getProperties().set("flat",true);
        addAndMakeVisible(message); message.setFont(theme::font(11)); message.setColour(Label::textColourId,theme::secondary);
        addAndMakeVisible(progress); progress.setPercentageDisplay(true);
        addAndMakeVisible(current); current.setFont(theme::font(12)); current.setColour(Label::textColourId,theme::secondary);
        refresh(); startTimerHz(10);
    }
    void paint(Graphics &g) override { g.fillAll(theme::panel); }
    void resized() override {
        search.setBounds(20,16,getWidth()-40,30); list.setBounds(16,100,getWidth()-32,getHeight()-(VST3Catalog::shared().scanning ? 226 : 166));
        const int half=(getWidth()-48)/2;
        typeLabel.setBounds(20,57,48,28); typeFilter.setBounds(68,57,half-48,28);
        vendorLabel.setBounds(28+half,57,68,28); vendorFilter.setBounds(96+half,57,half-68,28);
        current.setBounds(20,getHeight()-116,getWidth()-40,26);
        progress.setBounds(20,getHeight()-84,getWidth()-40,16);
        scan.setBounds(20,getHeight()-46,150,28); cancel.setBounds(getWidth()-110,getHeight()-46,90,28);
        retry.setBounds(180,getHeight()-46,125,28);
        const int messageLeft=retry.isVisible()?315:182;
        message.setBounds(messageLeft,getHeight()-46,std::max(20,getWidth()-messageLeft-124),28);
    }
  private:
    std::function<void(var)> picked; std::function<void()> dismiss;
    TextEditor search; ComboBox typeFilter,vendorFilter; Label typeLabel,vendorLabel; ListBox list; TextButton scan{"Escanear plugins"},retry{String::fromUTF8("Tentar falhas")},cancel{"Fechar"}; Label message;
    ProgressBar progress{VST3Catalog::shared().scanProgress}; Label current;
    Array<var> matches; String selected; uint64 revision = ~uint64(0);
    bool instrumentsAllowed = true;
    void refresh() {
        auto &catalog = VST3Catalog::shared(); matches.clear();
        auto rebuild=[](ComboBox &box,StringArray options) {
            const auto selected=box.getSelectedId()>1?box.getText():String{};
            options.removeDuplicates(false); options.removeEmptyStrings(); options.sort(true);
            box.clear(dontSendNotification); box.addItem("All",1); int id=2,selection=1;
            for (const auto &option : options) { box.addItem(option,id); if(option==selected)selection=id; ++id; }
            box.setSelectedId(selection,dontSendNotification);
        };
        if (revision != catalog.revision) {
            StringArray types,vendors;
            for (const auto &plugin : catalog.plugins) {
                if (!instrumentsAllowed && str(plugin,"category").containsIgnoreCase("Instrument")) continue;
                types.addArray(pluginTypes(plugin)); vendors.add(str(plugin,"vendor"));
            }
            rebuild(typeFilter,types); rebuild(vendorFilter,vendors);
        }
        const auto query=search.getText().trim();
        const auto type=typeFilter.getSelectedId()>1?typeFilter.getText():String{};
        const auto vendor=vendorFilter.getSelectedId()>1?vendorFilter.getText():String{};
        typeFilter.setEnabled(query.isEmpty()); vendorFilter.setEnabled(query.isEmpty());
        for (auto plugin : catalog.plugins) if(pluginMatches(plugin,query,type,vendor,instrumentsAllowed)) matches.add(plugin);
        list.updateContent(); list.repaint();
        message.setText(catalog.scanning ? catalog.status : String(matches.size()) + " plugins",dontSendNotification);
        scan.setButtonText(catalog.scanning?"Cancelar escaneamento":"Escanear plugins"); revision=catalog.revision;
        retry.setVisible(!catalog.scanning && catalog.hasFailedPlugins());
        const bool layoutChanged=progress.isVisible()!=catalog.scanning;
        progress.setVisible(catalog.scanning); current.setVisible(catalog.scanning);
        if(layoutChanged) if(auto *window=findParentComponentOfClass<DocumentWindow>()) window->setContentComponentSize(getWidth(),getHeight()+(catalog.scanning?60:-60));
        resized();
        updateScanProgress();
    }
    void updateScanProgress() {
        auto &catalog = VST3Catalog::shared();
        if (catalog.scanning) { current.setText(catalog.progressText(),dontSendNotification); current.setTooltip(catalog.currentPlugin); }
    }
    void timerCallback() override { if(revision!=VST3Catalog::shared().revision)refresh(); else updateScanProgress(); }
    int getNumRows() override { return (matches.size()+3)/4; }
    void paintListBoxItem(int row,Graphics &g,int width,int,bool) override {
        const int cell=width/4;
        for(int col=0;col<4;++col) {
            const int index=row*4+col;if(index>=matches.size())break;const auto &p=matches[index];
            const auto id=str(p,"classID")+str(p,"path");const auto bounds=juce::Rectangle<float>((float)(col*cell+4),4,(float)(cell-8),56);
            g.setColour(selected==id?theme::green.withAlpha(.16f):theme::display);g.fillRoundedRectangle(bounds,6);
            g.setColour(selected==id?theme::green:theme::line);g.drawRoundedRectangle(bounds,6,1);
            g.setColour(Colours::white);g.setFont(theme::font(12,true));g.drawFittedText(str(p,"name"),bounds.reduced(8).withHeight(28).toNearestInt(),Justification::topLeft,2);
            g.setColour(theme::secondary);g.setFont(theme::font(10));g.drawText(str(p,"vendor"),bounds.reduced(8).withTrimmedTop(28),Justification::topLeft,true);
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
