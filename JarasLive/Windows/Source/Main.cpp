#include "ConfirmationPanel.h"
#include "Workspace.h"
#include "RemoteProtocol.h"
#include "RemoteHost.h"
#include "StartupSplash.h"
#include "ShowMode.h"
#include "ProjectMigration.h"
#include "DesktopLayout.h"
#include "NativeWindowBounds.h"
#if CATLIVE_NATIVE_FRONTEND
#include "NativeFrontendHost.h"
#include "FrontendBridge.h"
#endif
#include <BinaryData.h>
namespace catlive {
class ProjectTabButton final : public QuietButton {
  public:
    explicit ProjectTabButton(const String &title) : QuietButton(title) {}
    void paintButton(Graphics &g, bool over, bool down) override {
        const bool active=(bool)getProperties()["activeTab"];
        g.setColour(active ? Colour(0xff333333) : Colour(0xff202020));
        g.fillRect(getLocalBounds());
        if(over || down){g.setColour(Colours::white.withAlpha(down?.06f:.025f));g.fillRect(getLocalBounds());}
        g.setColour(active?Colours::white:Colour(0xffa0a0a0));
        g.setFont(theme::semiboldFont(11));
        g.drawText(getButtonText().trim(),getLocalBounds().withTrimmedLeft(6).withTrimmedRight(24),Justification::centred,true);
    }
};
class ProjectTabCloseButton final : public QuietButton {
  public:
    void paintButton(Graphics &g,bool over,bool) override {
        if(over){g.setColour(Colours::white.withAlpha(.1f));g.fillRoundedRectangle(getLocalBounds().toFloat().reduced(2),3);}
        g.setColour(Colours::white.withAlpha(over?1.f:.6f));
        const auto centre=getLocalBounds().toFloat().getCentre();
        g.drawLine(centre.x-3,centre.y-3,centre.x+3,centre.y+3,1.2f);
        g.drawLine(centre.x+3,centre.y-3,centre.x-3,centre.y+3,1.2f);
    }
};
class ProjectTabsHost final : public Component, private Timer {
  public:
    Workspace *current = nullptr;
    std::function<std::vector<String>()> titles;
    std::function<size_t()> selected;
    std::function<void(size_t)> choose, closeTab;
    ProjectTabsHost() { viewport.setViewedComponent(&strip, false); viewport.setScrollBarsShown(false, false); addAndMakeVisible(viewport); startTimerHz(5); }
    ~ProjectTabsHost() override { detach(); viewport.setViewedComponent(nullptr, false); }
    void detach() {
        if (!current) return;
        current->addAndMakeVisible(current->windowCaption());
        removeChildComponent(current); current = nullptr;
    }
    void show(Workspace *workspace) {
        detach(); current = workspace;
        addAndMakeVisible(current); addAndMakeVisible(current->windowCaption());
        rebuild(); resized();
    }
    void paintOverChildren(Graphics &g) override {
        if (!current || !current->isProjectOpen() || buttons.size()<2 || lastSelected>=buttons.size()) return;
        const auto bounds=buttons[lastSelected]->getBounds();
        g.setColour(theme::green);
        g.fillRect(bounds.getX(),viewport.getY()+22,bounds.getWidth(),2);
    }
    void refresh() { lastSelected=size_t(-1); rebuild(); }
    void resized() override {
        if (!current) return;
        const int height = current->isProjectOpen() && buttons.size()>1 ? 24 : 0;
        current->setBounds(0, height, getWidth(), getHeight() - height);
        current->windowCaption().setBounds(0, 0, getWidth(), 32);
        viewport.setBounds(0, 32, getWidth(), height);
        viewport.setVisible(height > 0); viewport.toFront(false);
        strip.setSize(getWidth(), 24);
        const float cell = buttons.empty() ? 0.f : float(getWidth()-12+3)/float(buttons.size());
        for (size_t i = 0; i < buttons.size(); ++i) {
            const int x=6+roundToInt(float(i)*cell), right=6+roundToInt(float(i+1)*cell)-3;
            buttons[i]->setBounds(x, 1, jmax(0,right-x), 22);
            closeButtons[i]->setBounds(jmax(x,right-22), 2, 20, 20);
        }
    }
  private:
    Viewport viewport;
    Component strip;
    std::vector<std::unique_ptr<TextButton>> buttons;
    std::vector<std::unique_ptr<QuietButton>> closeButtons;
    std::vector<String> lastTitles;
    size_t lastSelected = size_t(-1);
    bool lastOpen = false;
    void timerCallback() override { rebuild(); }
    void rebuild() {
        const auto names = titles ? titles() : std::vector<String>{};
        const auto active = selected ? selected() : 0;
        const bool open = current && current->isProjectOpen();
        if (names == lastTitles && active == lastSelected && open == lastOpen) return;
        lastTitles = names; lastSelected = active; lastOpen = open;
        buttons.clear(); closeButtons.clear();
        for (size_t i = 0; i < names.size(); ++i) {
            auto button = std::make_unique<ProjectTabButton>(names[i]);
            button->setColour(TextButton::buttonColourId, i == active ? Colour(0xff343434) : Colour(0xff222222));
            button->setColour(TextButton::textColourOffId, i == active ? Colours::white : Colours::lightgrey);
            button->setTooltip(names[i]);
            button->getProperties().set("fontSize",11);
            button->onClick = [safe = SafePointer<ProjectTabsHost>(this), i] {
                MessageManager::callAsync([safe, i] { if (safe && safe->choose) safe->choose(i); });
            };
            button->getProperties().set("activeTab",i==active);
            strip.addAndMakeVisible(*button); buttons.push_back(std::move(button));
            auto close = std::make_unique<ProjectTabCloseButton>();
            close->getProperties().set("icon","close");close->getProperties().set("plain",true);
            close->setComponentID("closeProjectTab-"+String((int)i));
            close->setTooltip(localization::translate("Close tab"));
            close->onClick=[safe=SafePointer<ProjectTabsHost>(this),i] {
                MessageManager::callAsync([safe,i]{if(safe && safe->closeTab)safe->closeTab(i);});
            };
            strip.addAndMakeVisible(*close);closeButtons.push_back(std::move(close));
        }
        resized(); repaint();
    }
};
class CatLiveApplication final : public JUCEApplication {
  public:
    const String getApplicationName() override { return "CatLive"; }
    const String getApplicationVersion() override { return JUCE_APPLICATION_VERSION_STRING; }
    bool moreThanOneInstanceAllowed() override {
        auto args = getCommandLineParameters();
        return args.contains("--prepare-project-sync-cable") || args.contains("--self-test") || args.contains("--visual-test") ||
               args.contains("--grid-import-test") ||
               args.contains("--home-preview") || args.contains("--project-preview") || args.contains("--roundtrip-project") ||
               args.contains("--migrate-project");
    }
    class Window final : public DocumentWindow {
      public:
        Window(Workspace *content, Component *host, bool showImmediately)
            : DocumentWindow("CatLive", theme::background, 0) {
            setUsingNativeTitleBar(false);
            setTitleBarHeight(0);
            setContentNonOwned(host, true);
            setResizable(true, false);
            setDropShadowEnabled(true);
            setBackgroundColour(theme::background);
            setIcon(ImageCache::getFromMemory(BinaryData::icon2561x_png,
                                              BinaryData::icon2561x_pngSize));
            if (content->isLoginShowing()) {
                fitLoginWindow(*this);
            } else if (content->isProjectBrowserShowing()) {
                fitProjectBrowserWindow(*this);
            } else {
                fitEditorWindow(*this);
            }
            setVisible(showImmediately);
            if (auto *peer = getPeer()) {
                workArea.attach((HWND)peer->getNativeHandle());
                auto engines = peer->getAvailableRenderingEngines();
                const auto renderer=SystemStats::getEnvironmentVariable("CATLIVE_RENDERER",
                    Appearance{}.value("jaras.windows.renderer","Direct2D").toString());
                for (int i = 0; i < engines.size(); ++i)
                    if (engines[i].containsIgnoreCase(renderer))
                        peer->setCurrentRenderingEngine(i);
            }
        }
        NativeWindowBounds workArea;
        void closeButtonPressed() override {
            JUCEApplication::getInstance()->systemRequestedQuit();
        }
    };
    void initialise(const String &arguments) override {
        auto args = StringArray::fromTokens(arguments, true);
        args.removeEmptyStrings();
        for (auto &arg : args)
            arg = arg.unquoted();
        if (args.contains("--prepare-project-sync-cable")) {
            const auto i=args.indexOf("--prepare-project-sync-cable");
            const auto index=i+1<args.size()?args[i+1].getLargeIntValue():0;
            const auto hardware=i+2<args.size()?args[i+2]:String();
            const auto code=index>0 && index<=std::numeric_limits<ULONG>::max() && hardware.isNotEmpty()
                ?remote::SyncEthernet::prepareElevated((ULONG)index,hardware):ERROR_INVALID_PARAMETER;
            setApplicationReturnValue((int)code);quit();return;
        }
        if (args.contains("--migrate-project")) {
            auto i = args.indexOf("--migrate-project");
            try {
                if (i + 2 >= args.size())
                    throw std::runtime_error("Expected source and destination paths.");
                auto source = File(args[i + 1]);
                auto imported = source.hasFileExtension("rpp") ? readReaperProject(source, makeReaperVST3Resolver())
                                                               : readLogicProject(source);
                auto destination = saveMigratedProject(imported, File(args[i + 2]));
                auto report = object();
                put(report, "document", destination.getFullPathName());
                Array<var> warnings;
                for (auto &message : imported.warnings)
                    warnings.add(message);
                put(report, "warnings", var(warnings));
                File(args[i + 2])
                    .withFileExtension("migration.json")
                    .replaceWithText(JSON::toString(report));
            } catch (const std::exception &e) {
                testResult = 1;
                if (i + 2 < args.size())
                    File(args[i + 2])
                        .withFileExtension("migration.json")
                        .replaceWithText(String::fromUTF8(e.what()));
            }
            quit();
            return;
        }
        if (args.contains("--roundtrip-project")) {
            auto i = args.indexOf("--roundtrip-project");
            try {
                if (i + 2 >= args.size())
                    throw std::runtime_error("Expected input and output project paths.");
                auto timings=object();auto started=Time::getMillisecondCounterHiRes();
                const auto record=[&](const char *stage){const auto now=Time::getMillisecondCounterHiRes();put(timings,stage,now-started);started=now;};
                auto original = ProjectCodec::read(File(args[i + 1]));record("readMilliseconds");
                auto model = ProjectCodec::decode(original);record("decodeMilliseconds");
                auto encoded=ProjectCodec::encode(model, original);record("encodeMilliseconds");
                ProjectCodec::write(File(args[i + 2]),encoded);record("writeMilliseconds");
                File(args[i+2]).withFileExtension("roundtrip-timing.json").replaceWithText(JSON::toString(timings));
            } catch (const std::exception &e) {
                testResult = 1;
                if (i+2<args.size()) File(args[i+2]).withFileExtension("roundtrip-error.txt").replaceWithText(String::fromUTF8(e.what()));
            }
            quit();
            return;
        }
        if (args.contains("--self-test")) {
            auto i = args.indexOf("--self-test");
            testResult = runTests(
                i + 1 < args.size()
                    ? File(args[i + 1])
                    : File::getSpecialLocation(File::tempDirectory).getChildFile("CatLiveTests"));
            quit();
            return;
        }
        try {
            const bool previewHome = args.contains("--home-preview");
            // Keep control descriptions for accessibility without hover popups.
            const bool projectPreview = args.contains("--project-preview");
            const bool gridImportTest = args.contains("--grid-import-test");
            const bool visualTest = args.contains("--visual-test") || projectPreview || gridImportTest;
            File appearanceFile;
            const int appearanceArgument = args.indexOf("--appearance-file");
            if ((visualTest || previewHome) && appearanceArgument >= 0 && appearanceArgument + 1 < args.size())
                appearanceFile = File(args[appearanceArgument + 1]);
            float scale = Appearance(appearanceFile).interfaceScale();
            const int scaleArg = args.indexOf("--ui-scale");
            if (scaleArg >= 0 && scaleArg + 1 < args.size()) {
                const auto requested = args[scaleArg + 1].getFloatValue();
                if (std::isfinite(requested) && requested > 0) scale = std::round(jlimit(.6f, 1.2f, requested) * 10) / 10;
            }
            Desktop::getInstance().setGlobalScaleFactor(scale);
            if (!visualTest)
                splash = std::make_unique<StartupSplash>();
            session = std::make_unique<Session>();
            auth = std::make_unique<Auth>();
            lighting = std::make_unique<Lighting>(*session);
            session->canPlay = [this] { return auth->allowed() && !auth->pendingRevocation; };
            auth->isPlaying = [this] {
                return std::any_of(tabSessions.begin(), tabSessions.end(), [](auto *s) { return s->transport().playing || s->transport().subPlay.playing; });
            };
            session->playbackUpdate = [this](const jaras::TransportState &state) {
                lighting->update(state);
            };
            if (gridImportTest) {
                session->inspection = true;
                session->audio.prepareOffline(48000);
                session->audio.setOffline(true);
            } else if (args.contains("--visual-test")) {
                session->makeInspectionProject(args.contains("--audio-fixture"));
                lighting->loadSettings();
            } else if (projectPreview) {
                const int index = args.indexOf("--project-preview");
                if (index + 1 >= args.size()) throw std::runtime_error("Expected preview project path");
                session->inspection = true;
                if (args.contains("--inspect-audio")) {
                    const auto error = session->audio.openDevice();
                    if (error.isNotEmpty()) throw std::runtime_error(utf8(error));
                }
                session->load(File(args[index + 1]));
            } else if (previewHome) {
                // Visual inspection never grants an audio entitlement.
                session->inspection = true;
            } else {
                auto error = session->audio.openDevice();
                if (error.isNotEmpty())
                    session->message = error;
                auth->restore();
            }
            if (!visualTest && !previewHome) { showMode = ShowMode::shared(); showMode->start(); }
#if CATLIVE_NATIVE_FRONTEND
            if (args.contains("--native-ui")) {
                startNativeFrontend(args);
                return;
            }
#endif
            firstWorkspace = std::make_unique<Workspace>(*session, *auth, *lighting, previewHome, appearanceFile);
            auto *content = firstWorkspace.get();
            tabWorkspaces.push_back(content); tabSessions.push_back(session.get());
            installProjectTabHooks(*content);
            tabHost = std::make_unique<ProjectTabsHost>();
            tabHost->titles = [this] {
                std::vector<String> names;
                for (auto *tab : tabSessions) names.push_back(tab->document.existsAsFile() ? tab->document.getFileNameWithoutExtension() : String::fromUTF8(tab->project().name.c_str()));
                return names;
            };
            tabHost->selected = [this] { return selectedTab; };
            tabHost->choose = [this](size_t index) { selectProjectTab(index); };
            tabHost->closeTab = [this](size_t index) { closeProjectTab(index); };
            tabHost->show(content);
            window = std::make_unique<Window>(content, tabHost.get(), visualTest);
            if (previewHome)
                content->showProjectBrowser();
            if (previewHome && args.contains("--login-preview"))
                content->showLoginPreview();
            if (previewHome && args.contains("--import-notice-preview"))
                content->showImportNoticePreview();
            if (!visualTest)
                Timer::callAfterDelay(1600, [this] {
                    if (closing) return;
                    if (window) {
                        window->setVisible(true);
                        window->toFront(true);
                    }
                    splash.reset();
                });
            if (args.contains("--visual-test"))
                content->runUIRegression();
            if (gridImportTest) {
                const int i = args.indexOf("--grid-import-test");
                if (i + 1 >= args.size()) throw std::runtime_error("Expected grid import test results directory");
                const File results(args[i + 1]);
                Timer::callAfterDelay(300, [this, content, results] {
                    content->runMediaImportRegression(results, [this](bool passed) {
                        testResult = passed ? 0 : 1;
                        quit();
                    });
                });
            }
            if (args.contains("--capture")) {
                auto i = args.indexOf("--capture");
                if (i + 1 < args.size()) {
                    File output(args[i + 1]);
                    auto close = args.contains("--quit-after-capture");
                    Timer::callAfterDelay(1500, [this, content, output, close] {
                        content->capture(output);
                        if (close)
                            quit();
                    });
                }
            }
            for (auto &arg : args)
                if (!projectPreview && File::isAbsolutePath(arg) && File(arg).hasFileExtension("jl;bkjl;ziplive;zip")) {
                    const File source(arg);
                    // Let the startup splash hand over to the workspace first.
                    // Cached peaks can otherwise reach the UI-thread audio/FX
                    // preparation before the progress sheet is visible.
                    Timer::callAfterDelay(1700, [safe=Component::SafePointer<Workspace>(content),source]{if(safe)safe->openProject(source);});
                    break;
                }
        } catch (const std::exception &e) {
            AlertWindow::showMessageBoxAsync(MessageBoxIconType::WarningIcon, "CatLive",
                                             String::fromUTF8(e.what()), "Fechar", nullptr,
                                             ModalCallbackFunction::create([this](int) {
                                                 testResult = 1;
                                                 quit();
                                             }));
        }
    }
    void shutdown() override {
        if (showMode) { showMode->stop(); showMode.reset(); }
        splash.reset();
#if CATLIVE_NATIVE_FRONTEND
        nativeBridge.reset();
        nativeFrontend.reset();
#endif
        window.reset();
        tabHost.reset();
        extraTabs.clear();
        firstWorkspace.reset(); tabWorkspaces.clear(); tabSessions.clear();
        lighting.reset();
        auth.reset();
        session.reset();
        setApplicationReturnValue(testResult);
    }
    void systemRequestedQuit() override {
#if CATLIVE_NATIVE_FRONTEND
        if (nativeBridge && !closing) { nativeBridge->requestClose(); return; }
#endif
        if(jaras::projectSync::readOnly()) {
            if(tabHost && tabHost->current)tabHost->current->showError(String::fromUTF8("Project Sync: o PC B está seguindo o PC A. Desative a sincronização antes de encerrar."));
            return;
        }
        if (closing) {
            if (splash) splash->toFront(false);
            return;
        }
        if (window)
            if (auto *w = (tabHost ? tabHost->current : nullptr)) {
                requestTabClosing(0);
                return;
            }
        quit();
    }
    void anotherInstanceStarted(const String &arguments) override {
#if CATLIVE_NATIVE_FRONTEND
        if (!closing && nativeFrontend) {
            nativeFrontend->show();
            auto args = StringArray::fromTokens(arguments, true);
            for (auto arg : args)
                if (File::isAbsolutePath(arg.unquoted()) && File(arg.unquoted()).hasFileExtension("jl;bkjl;ziplive;zip")) {
                    if (nativeBridge) nativeBridge->openProject(File(arg.unquoted()));
                    break;
                }
            return;
        }
#endif
        if (closing || !window) return;
        window->toFront(true);
        auto args = StringArray::fromTokens(arguments, true);
        for (auto arg : args)
            if (File::isAbsolutePath(arg.unquoted()) && File(arg.unquoted()).hasFileExtension("jl;bkjl;ziplive;zip")) {
                if (auto *w = (tabHost ? tabHost->current : nullptr))
                    w->openProject(File(arg.unquoted()));
                break;
            }
    }

  private:
#if CATLIVE_NATIVE_FRONTEND
    void startNativeFrontend(const StringArray& args) {
        // Retain the shipping Session, authorization and audio device. Only the
        // presentation changes: no Workspace or hidden JUCE editor is created.
        tabSessions.push_back(session.get());
        nativeBridge = std::make_unique<FrontendBridge>(*session, *auth, [this](const String& json) {
            if (nativeFrontend) nativeFrontend->postJSON(utf8(json));
        });
        nativeBridge->onCloseApproved = [this] {
            if (closing) return;
            closing = true;
            session->command(jaras::CommandKind::stopAll);
            session->audio.instrumentAllowed = false;
            if (nativeFrontend) nativeFrontend->close();
            quit();
        };
        const auto executable = File::getSpecialLocation(File::currentExecutableFile).getParentDirectory();
        const auto cache = File(SystemStats::getEnvironmentVariable("LOCALAPPDATA",
            File::getSpecialLocation(File::userApplicationDataDirectory).getFullPathName()))
            .getChildFile("Hook Developer/CatLive/NativeFrontend");
        NativeFrontendHost::Options options;
        options.assetDirectory = executable.getChildFile("native-ui").getFullPathName().toWideCharPointer();
        options.userDataDirectory = cache.getFullPathName().toWideCharPointer();
        options.title = (String("CatLive Version ") + getApplicationVersion() + " — Interface Windows (avaliação)").toWideCharPointer();
        NativeFrontendHost::Callbacks actions;
        actions.message = [this](std::string json) {
            if (nativeBridge && !closing) nativeBridge->receive(String::fromUTF8(json.data(), static_cast<int>(json.size())));
        };
        actions.ready = [this, args] {
            if (closing) return;
            splash.reset();
            if (nativeFrontend) nativeFrontend->show();
            if (nativeBridge) nativeBridge->publishSnapshot();
            for (const auto& argument : args)
                if (File::isAbsolutePath(argument) && File(argument).hasFileExtension("jl;bkjl;ziplive;zip")) {
                    if (nativeBridge) nativeBridge->openProject(File(argument));
                    break;
                }
        };
        actions.closeRequested = [this] { systemRequestedQuit(); };
        actions.error = [this](std::string error) {
            // Fail visibly without opening a second editor or granting access.
            MessageManager::callAsync([this, error = std::move(error)] {
                if (closing) return;
                splash.reset();
                const auto message = String::fromUTF8(error.c_str());
                MessageBoxW(nativeFrontend ? nativeFrontend->handle() : nullptr,
                    message.toWideCharPointer(), L"CatLive", MB_OK | MB_ICONERROR);
                testResult = 1;
                quit();
            });
        };
        nativeFrontend = std::make_unique<NativeFrontendHost>(std::move(options), std::move(actions));
        nativeBridge->setOwnerWindow(nativeFrontend->handle());
    }
    std::unique_ptr<NativeFrontendHost> nativeFrontend;
    std::unique_ptr<FrontendBridge> nativeBridge;
#endif
    void beginClosing() {
        if (closing) return;
        closing = true;
        auto bounds = window ? window->getScreenBounds() : juce::Rectangle<int>{};
        splash.reset();
        hiddenWindows.clear();
        auto &desktop = Desktop::getInstance();
        for (int i = 0; i < desktop.getNumComponents(); ++i) {
            auto *component = desktop.getComponent(i);
            if (component->isVisible()) hiddenWindows.emplace_back(component);
        }
        splash = std::make_unique<StartupSplash>(true, bounds);
        for (auto &component : hiddenWindows) if (component) component->setVisible(false);
        // Return to the message loop so the transparent artwork paints before device teardown.
        Timer::callAfterDelay(40, [this] {
            try {
                for (auto *projectSession : tabSessions) {
                    projectSession->command(jaras::CommandKind::stopAll);
                    projectSession->audio.instrumentAllowed = false;
                    projectSession->audio.closeDevice();
                }
                splash->advanceClosing(.25);
                splash->advanceClosing(.85);
                // Briefly keep the closing panel readable even on a fast machine.
                Timer::callAfterDelay(600, [this] {
                    splash->advanceClosing(1);
                    Timer::callAfterDelay(100, [this] { quit(); });
                });
            } catch (const std::exception &e) {
                splash.reset();
                for (auto &component : hiddenWindows) if (component) component->setVisible(true);
                hiddenWindows.clear();
                closing = false;
                if (window) {
                    window->toFront(true);
                    if (auto *w = (tabHost ? tabHost->current : nullptr))
                        w->showError(String::fromUTF8(e.what()));
                }
            }
        });
    }
    struct ProjectTab {
        std::unique_ptr<Session> session;
        std::unique_ptr<Lighting> lighting;
        std::unique_ptr<Workspace> workspace;
    };
    std::unique_ptr<ProjectTabsHost> tabHost;
    std::unique_ptr<Workspace> firstWorkspace;
    std::vector<std::unique_ptr<ProjectTab>> extraTabs;
    std::vector<Workspace *> tabWorkspaces;
    std::vector<Session *> tabSessions;
    size_t selectedTab = 0;
    std::map<std::pair<ID,ID>,bool> syncApplied;
    void installProjectTabHooks(Workspace &workspace) {
        auto &sync=workspace.projectRemoteHost()->sync;
        sync.resetApplied=[this]{syncApplied.clear();};
        sync.confirm=[this](String message,std::function<void(bool)> reply) {
            auto *owner=tabHost?tabHost->current:nullptr;
            ConfirmationPanel::show(MessageBoxIconType::QuestionIcon,"Project Sync",message,
                "Aceitar","Cancelar",owner,ModalCallbackFunction::create([reply](int result){reply(result!=0);}));
        };
        sync.audioIdentity=[this] {
            if(selectedTab>=tabSessions.size()) return String();
            auto *device=tabSessions[selectedTab]->audio.devices.getCurrentAudioDevice();
            return device && device->isOpen()?device->getTypeName()+":"+device->getName():String();
        };
        sync.snapshot=[this] {
            auto result=object(); Array<var> tabs;
            if(selectedTab>=tabSessions.size()) return result;
            const auto &active=tabSessions[selectedTab]->project().projectSyncID;
            if(active) put(result,"active",text(*active));
            std::set<ID> seen;
            for(size_t i=0;i<tabSessions.size();++i) {
                auto &session=*tabSessions[i]; const auto &id=session.project().projectSyncID;
                if(!tabWorkspaces[i]->isProjectOpen() || session.busy || !id || !seen.insert(*id).second) continue;
                auto tab=object();put(tab,"project",text(*id));put(tab,"name",text(session.project().name));
                if(session.focusedRegion)put(tab,"focusedRegion",text(*session.focusedRegion));
                const auto data=jaras::projectSync::encode(session.projectSyncFrame());
                put(tab,"transport",Base64::toBase64(data.data(),data.size()));tabs.add(tab);
            }
            put(result,"tabs",var(tabs));return result;
        };
        sync.apply=[this](const var &message,double elapsed,const ID &connection) {
            remote::ProjectSync::ApplyResult result;
            StringArray missing;std::set<ID> seen;
            auto *tabs=message["tabs"].getArray();if(!tabs) return result;
            for(const auto &tab:*tabs) {
                if(!remote::validID(tab["project"]) || !tab["transport"].isString() || tab["transport"].toString().length()>174764) continue;
                const auto id=utf8(tab["project"].toString());if(!seen.insert(id).second) continue;
                size_t index=0;
                for(;index<tabSessions.size();++index) {
                    const auto &candidate=tabSessions[index]->project().projectSyncID;
                    if(candidate && jaras::projectSync::sameID(*candidate,id) && tabWorkspaces[index]->isProjectOpen() && !tabSessions[index]->busy)break;
                }
                if(index==tabSessions.size()) {missing.add(tab["name"].toString().substring(0,128));continue;}
                try {
                    if(tabSessions[index]->audio.isRecording()) throw std::runtime_error("Conclua a gravação antes de sincronizar.");
                    MemoryOutputStream bytes;
                    if(!Base64::convertFromBase64(bytes,tab["transport"].toString())) throw std::runtime_error("Invalid Project Sync frame");
                    auto frame=jaras::projectSync::decode((const uint8_t*)bytes.getData(),bytes.getDataSize());
                    if(!jaras::projectSync::sameID(frame.project,id))throw std::runtime_error("Invalid Project Sync project");
                    auto key=std::make_pair(connection,id);
                    const auto age=tab.hasProperty("age")?(double)tab["age"]:0.;
                    if(!std::isfinite(age) || age<0 || age>1)throw std::runtime_error("Invalid Project Sync clock");
                    std::optional<ID> focus;
                    if(remote::validID(tab["focusedRegion"]))focus=utf8(tab["focusedRegion"].toString());
                    tabSessions[index]->applyProjectSync(frame,std::min(1.,elapsed+age),!syncApplied[key],focus);
                    syncApplied[key]=true;result.applied=true;
                } catch(const std::exception &e) { result.problem=String::fromUTF8(e.what()); }
            }
            const auto active=utf8(message["active"].toString());
            for(size_t i=0;i<tabSessions.size();++i) if(auto id=tabSessions[i]->project().projectSyncID;id && jaras::projectSync::sameID(*id,active)) {
                if(i!=selectedTab)selectProjectTab(i);break;
            }
            if(!missing.isEmpty())result.problem=String::fromUTF8("Abra este projeto também no PC B: ")+missing.joinIntoString(", ");
            return result;
        };
        workspace.remoteProjectTabs = [this] {
            Array<var> tabs;
            for (size_t index = 0; index < tabWorkspaces.size(); ++index) {
                auto tab = object();
                put(tab, "id", remote::wireID(tabWorkspaces[index]->remoteProjectTabID));
                put(tab, "name", tabSessions[index]->document.existsAsFile() ? tabSessions[index]->document.getFileNameWithoutExtension() : String::fromUTF8(tabSessions[index]->project().name.c_str()));
                put(tab, "selected", index == selectedTab);
                tabs.add(tab);
            }
            return var(tabs);
        };
        workspace.selectRemoteProjectTab = [this](const String &id) {
            for (size_t index = 0; index < tabWorkspaces.size(); ++index)
                if (remote::wireID(tabWorkspaces[index]->remoteProjectTabID) == id) { if (index != selectedTab) selectProjectTab(index); return; }
        };
        workspace.closeRemoteProjectTab = [this](const String &id) {
            for (size_t index = 0; index < tabWorkspaces.size(); ++index)
                if (remote::wireID(tabWorkspaces[index]->remoteProjectTabID) == id) { closeProjectTab(index); return; }
        };
        workspace.activateExistingProjectTab = [this](File file) {
            for (size_t index = 0; index < tabSessions.size(); ++index)
                if (index != selectedTab && tabSessions[index]->document == file) { selectProjectTab(index); return true; }
            return false;
        };
        workspace.openInNewProjectTab = [this](File file) { openProjectTab(file); };
        workspace.openRemoteProjectInNewTab = [this](File file, ID request) { openProjectTab(file, request); };
        workspace.navigateProjectTab = [this](int direction) {
            if (tabWorkspaces.size() < 2 || selectedTab >= tabSessions.size() || tabSessions[selectedTab]->busy || tabSessions[selectedTab]->audio.isRecording()) return;
            if ((direction < 0 && selectedTab == 0) || (direction > 0 && selectedTab + 1 >= tabWorkspaces.size())) return;
            const auto next = direction < 0 ? selectedTab - 1 : selectedTab + 1;
            selectProjectTab(next);
        };
        workspace.canNavigateProjectTab = [this](int direction) {
            return tabWorkspaces.size() > 1 && (direction < 0 ? selectedTab > 0 : selectedTab + 1 < tabWorkspaces.size());
        };
    }
    void selectProjectTab(size_t index) {
        if (!window || index >= tabWorkspaces.size()) return;
        if (selectedTab < tabSessions.size() && (tabSessions[selectedTab]->busy || tabSessions[selectedTab]->audio.isRecording())) return;
        if (auto *old = (tabHost ? tabHost->current : nullptr)) { old->deactivateProjectTab(); old->setVisible(false); }
        selectedTab = index;
        auto *content = tabWorkspaces[index];
        tabHost->show(content);
        content->setVisible(true);
        content->activateProjectTab();
        content->grabKeyboardFocus();
    }
    void openProjectTab(const File &file, ID remoteRequest = {}) {
        const auto host = firstWorkspace->projectRemoteHost();
        if (!file.existsAsFile()) {
            host->projectOpening.update(remoteRequest, remote::ProjectOpening::State::failed, {}, "This project is no longer available in the PC's recent projects.");
            return;
        }
        for (size_t index = 0; index < tabSessions.size(); ++index)
            if (tabSessions[index]->document == file) {
                selectProjectTab(index);
                host->projectOpening.update(remoteRequest, remote::ProjectOpening::State::completed);
                return;
            }
        if (tabSessions[selectedTab]->busy || tabSessions[selectedTab]->audio.isRecording()) {
            host->projectOpening.update(remoteRequest, remote::ProjectOpening::State::failed, {}, "Wait for the current operation or stop recording on the PC.");
            return;
        }
        try {
            const size_t previousTab = selectedTab;
            auto tab = std::make_unique<ProjectTab>();
            tab->session = std::make_unique<Session>(session->audio.deviceHost);
            tab->session->inspection = session->inspection;
            tab->session->canPlay = [this] { return auth->allowed() && !auth->pendingRevocation; };
            if (!tab->session->inspection) {
                const auto error = tab->session->audio.openDevice();
                if (error.isNotEmpty()) throw std::runtime_error(utf8(error));
            }
            tab->lighting = std::make_unique<Lighting>(*tab->session);
            auto *lights = tab->lighting.get();
            tab->session->playbackUpdate = [lights](const jaras::TransportState &state) { lights->update(state); };
            tab->workspace = std::make_unique<Workspace>(*tab->session, *auth, *tab->lighting, false, File{}, firstWorkspace->projectRemoteHost());
            auto *workspace = tab->workspace.get();
            installProjectTabHooks(*workspace);
            workspace->projectTabLoadFinished = [this, previousTab, workspace](String error) {
                MessageManager::callAsync([this, previousTab, workspace, error] {
                    workspace->projectTabLoadFinished = {};
                    if (error.isEmpty()) return;
                    auto at = std::find(tabWorkspaces.begin(), tabWorkspaces.end(), workspace);
                    if (at == tabWorkspaces.end()) return;
                    const auto index = size_t(at - tabWorkspaces.begin());
                    if (selectedTab == index) selectProjectTab(previousTab);
                    tabWorkspaces.erase(at); tabSessions.erase(tabSessions.begin() + (ptrdiff_t)index);
                    extraTabs.erase(std::remove_if(extraTabs.begin(), extraTabs.end(), [workspace](const auto &tab) { return tab->workspace.get() == workspace; }), extraTabs.end());
                    tabWorkspaces[selectedTab]->activateProjectTab();
                    tabWorkspaces[selectedTab]->showError(error);
                });
            };
            tabWorkspaces.push_back(workspace); tabSessions.push_back(tab->session.get());
            extraTabs.push_back(std::move(tab));
            selectProjectTab(tabWorkspaces.size() - 1);
            workspace->openProject(file, {}, false, false, remoteRequest);
        } catch (const std::exception &error) {
            host->projectOpening.update(remoteRequest, remote::ProjectOpening::State::failed, {}, error.what());
            tabWorkspaces[selectedTab]->activateProjectTab();
            tabWorkspaces[selectedTab]->showError(String::fromUTF8(error.what()));
        }
    }
    void closeProjectTab(size_t index) {
        if (closing || index>=tabWorkspaces.size() || tabSessions[selectedTab]->busy || tabSessions[selectedTab]->audio.isRecording()) return;
        selectProjectTab(index);
        auto *workspace=tabWorkspaces[index];
        workspace->requestClose([this,workspace] {
            MessageManager::callAsync([this,workspace] {
                if(closing)return;
                auto at=std::find(tabWorkspaces.begin(),tabWorkspaces.end(),workspace);
                if(at==tabWorkspaces.end())return;
                const auto index=size_t(at-tabWorkspaces.begin());
                if(tabWorkspaces.size()==1) {
                    if(workspace!=firstWorkspace.get())selectProjectTab(index);
                    workspace->deactivateProjectTab();
                    tabHost->detach();
                    firstWorkspace->resetProjectTab();
                    tabWorkspaces={firstWorkspace.get()};tabSessions={session.get()};selectedTab=0;
                    tabHost->show(firstWorkspace.get());firstWorkspace->activateProjectTab();
                    extraTabs.clear();
                    return;
                }
                selectProjectTab(index==0?1:index-1);
                tabSessions[index]->command(jaras::CommandKind::stopAll);
                if(workspace==firstWorkspace.get())workspace->resetProjectTab();
                tabWorkspaces.erase(tabWorkspaces.begin()+(ptrdiff_t)index);
                tabSessions.erase(tabSessions.begin()+(ptrdiff_t)index);
                if(selectedTab>index)--selectedTab;
                extraTabs.erase(std::remove_if(extraTabs.begin(),extraTabs.end(),[workspace](const auto &tab){return tab->workspace.get()==workspace;}),extraTabs.end());
                tabWorkspaces[selectedTab]->activateProjectTab();
                tabHost->refresh();
            });
        },false);
    }
    void requestTabClosing(size_t index) {
        if (index >= tabWorkspaces.size()) { beginClosing(); return; }
        selectProjectTab(index);
        tabWorkspaces[index]->requestClose([this, index] { requestTabClosing(index + 1); });
    }
    bool closing = false;
    std::vector<Component::SafePointer<Component>> hiddenWindows;
    int testResult = 0;
    std::shared_ptr<ShowMode> showMode;
    std::unique_ptr<Session> session;
    std::unique_ptr<Auth> auth;
    std::unique_ptr<Lighting> lighting;
    std::unique_ptr<Window> window;
    std::unique_ptr<StartupSplash> splash;
};
} // namespace catlive
START_JUCE_APPLICATION(catlive::CatLiveApplication)
