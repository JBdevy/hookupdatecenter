#include "Workspace.h"
#include "StartupSplash.h"
#include "ProjectMigration.h"
#include "DesktopLayout.h"
#include "NativeWindowBounds.h"
#include <BinaryData.h>
namespace catlive {
class CatLiveApplication final : public JUCEApplication {
  public:
    const String getApplicationName() override { return "CatLive"; }
    const String getApplicationVersion() override { return JUCE_APPLICATION_VERSION_STRING; }
    bool moreThanOneInstanceAllowed() override {
        auto args = getCommandLineParameters();
        return args.contains("--self-test") || args.contains("--visual-test") ||
               args.contains("--grid-import-test") ||
               args.contains("--home-preview") || args.contains("--project-preview") || args.contains("--roundtrip-project") ||
               args.contains("--migrate-project");
    }
    class Window final : public DocumentWindow {
      public:
        Window(Workspace *content, bool showImmediately)
            : DocumentWindow("CatLive", theme::background, 0) {
            setUsingNativeTitleBar(false);
            setTitleBarHeight(0);
            setContentOwned(content, true);
            setResizable(true, false);
            setDropShadowEnabled(true);
            setBackgroundColour(theme::background);
            setIcon(ImageCache::getFromMemory(BinaryData::icon2561x_png,
                                              BinaryData::icon2561x_pngSize));
            if (content->isProjectBrowserShowing()) {
                fitProjectBrowserWindow(*this);
            } else {
                fitEditorWindow(*this);
            }
            setVisible(showImmediately);
            if (auto *peer = getPeer()) {
                workArea.attach((HWND)peer->getNativeHandle());
                auto engines = peer->getAvailableRenderingEngines();
                for (int i = 0; i < engines.size(); ++i)
                    if (engines[i].containsIgnoreCase("Direct2D"))
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
        if (args.contains("--migrate-project")) {
            auto i = args.indexOf("--migrate-project");
            try {
                if (i + 2 >= args.size())
                    throw std::runtime_error("Expected source and destination paths.");
                auto source = File(args[i + 1]);
                auto imported = source.hasFileExtension("rpp") ? readReaperProject(source)
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
                auto original = ProjectCodec::read(File(args[i + 1]));
                auto model = ProjectCodec::decode(original);
                ProjectCodec::write(File(args[i + 2]), ProjectCodec::encode(model, original));
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
                return session->transport().playing || session->transport().subPlay.playing;
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
            auto *content = new Workspace(*session, *auth, *lighting, previewHome, appearanceFile);
            window = std::make_unique<Window>(content, visualTest);
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
                    if (source.hasFileExtension("ziplive;zip"))
                        Timer::callAfterDelay(1700, [safe=Component::SafePointer<Workspace>(content),source]{if(safe)safe->openProject(source);});
                    else content->openProject(source);
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
        splash.reset();
        window.reset();
        lighting.reset();
        auth.reset();
        session.reset();
        setApplicationReturnValue(testResult);
    }
    void systemRequestedQuit() override {
        if (closing) {
            if (splash) splash->toFront(false);
            return;
        }
        if (window)
            if (auto *w = dynamic_cast<Workspace *>(window->getContentComponent())) {
                w->requestClose([this] { beginClosing(); });
                return;
            }
        quit();
    }
    void anotherInstanceStarted(const String &arguments) override {
        if (closing || !window) return;
        window->toFront(true);
        auto args = StringArray::fromTokens(arguments, true);
        for (auto arg : args)
            if (File::isAbsolutePath(arg.unquoted()) && File(arg.unquoted()).hasFileExtension("jl;bkjl;ziplive;zip")) {
                if (auto *w = dynamic_cast<Workspace *>(window->getContentComponent()))
                    w->openProject(File(arg.unquoted()));
                break;
            }
    }

  private:
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
                if (session) {
                    session->command(jaras::CommandKind::stopAll);
                    splash->advanceClosing(.25);
                    session->audio.instrumentAllowed = false;
                    session->audio.closeDevice();
                }
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
                    if (auto *w = dynamic_cast<Workspace *>(window->getContentComponent()))
                        w->showError(String::fromUTF8(e.what()));
                }
            }
        });
    }
    bool closing = false;
    std::vector<Component::SafePointer<Component>> hiddenWindows;
    int testResult = 0;
    std::unique_ptr<Session> session;
    std::unique_ptr<Auth> auth;
    std::unique_ptr<Lighting> lighting;
    std::unique_ptr<Window> window;
    std::unique_ptr<StartupSplash> splash;
};
} // namespace catlive
START_JUCE_APPLICATION(catlive::CatLiveApplication)
