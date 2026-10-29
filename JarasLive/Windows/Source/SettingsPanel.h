#pragma once
#include "Localization.h"
#include "ActionsPage.h"
#include "Auth.h"
#include "Lighting.h"
#include "VST3Catalog.h"
#include "ShowMode.h"
namespace catlive {
class SettingsPanel final : public Component, private Timer {
  public:
    SettingsPanel(Session &s, Auth &a, Lighting &l, Appearance &p, ActionBindings &bindings,
                  int initial, std::function<void(String)> fail, std::function<void()> signIn,
                  std::function<void()> audioWarning = {})
        : session(s), auth(a), lighting(l), preferences(p), actions(bindings),
          error(std::move(fail)), login(std::move(signIn)), warnAudio(std::move(audioWarning)) {
        const StringArray names{"Geral",       String::fromUTF8("Áudio"),
                                "MIDI",        String::fromUTF8("Ações"),
                                "Mapeamentos", "Plugins",
                                "Conta"};
        const char *icons[]{"mixer",    "speaker", "piano",  "keyboard",
                            "mappings", "plugins", "account"};
        for (int i = 0; i < names.size(); ++i) {
            auto *tab = tabs.add(new TextButton(names[i]));
            addAndMakeVisible(tab);
            tab->setComponentID("settingsTab" + String(i));
            tab->getProperties().set("plain", true);
            tab->getProperties().set("flat", true);
            tab->getProperties().set("leadingIcon", icons[i]);
            tab->getProperties().set("fontSize", 13.f);
            tab->setColour(TextButton::buttonOnColourId, theme::green.withAlpha(.15f));
            tab->setColour(TextButton::textColourOnId, Colours::white);
            tab->onClick = [this, i] { selectPage(i); };
        }
        addAndMakeVisible(viewport);
        viewport.setViewedComponent(&page, false);
        viewport.setScrollBarsShown(true, true);
        select(initial);

        startTimerHz(4);
    }
    ~SettingsPanel() override { stopTimer(); }
    void selectPage(int index) {
        if (isPositiveAndBelow(index, tabs.size()) && selected != index) {
            select(index);

        }
    }
    void cancelLearning() { actions.cancel(); }
    bool keyPressed(const KeyPress &key) override { return actions.captureKey(key); }
    void paint(Graphics &g) override {
        g.setColour(theme::background);
        g.fillRoundedRectangle(getLocalBounds().toFloat(), 16);
        g.setColour(theme::panel);
        g.fillRect(0, 0, 144, getHeight());
        g.setColour(theme::line);
        g.drawVerticalLine(144, 0, (float)getHeight());
    }
    void resized() override {
        const int tabStep = jlimit(32, 46, (getHeight() - 20) / tabs.size());
        for (int i = 0; i < tabs.size(); ++i)
            tabs[i]->setBounds(10, 10 + i * tabStep, 124, tabStep - 6);
        viewport.setBounds(145, 0, getWidth() - 145, getHeight());
        if (selected == 6) {
            page.setSize(std::max(360, viewport.getWidth()), contentHeight);
            layoutAccount();
            return;
        }
        int contentWidth = selected == 0 ? 240 : 620;
        if (selected == 0)
            for (auto *field : fields)
                if (dynamic_cast<Label *>(field))
                    field->setSize(std::max(240, viewport.getWidth() - 48), field->getHeight());
        for (auto *field : fields)
            contentWidth = std::max(contentWidth, field->getRight() + 12);
        page.setSize(std::max(contentWidth, viewport.getWidth() - 10), contentHeight);
        if (actionPage)
            actionPage->setBounds(24, 70, page.getWidth() - 48, getHeight() - 82);
    }

  private:
    Session &session;
    Auth &auth;
    Lighting &lighting;
    Appearance &preferences;
    ActionBindings &actions;
    std::function<void(String)> error;
    std::function<void()> login;
    std::function<void()> warnAudio;
    int selected = 0, contentHeight = 500;
    bool audioPageLocked = false;
    OwnedArray<TextButton> tabs;
    Viewport viewport;
    Component page;
    OwnedArray<Component> fields;
    ActionsPage *actionPage = nullptr;
    SafePointer<TextButton> accountLogin, accountLogout;
    SafePointer<Label> accountTitle, accountEmail, accountMessage;
    OwnedArray<Component> deviceFields;
    String deviceSnapshot;
    std::shared_ptr<ShowMode> showMode = ShowMode::shared();
    SafePointer<ComboBox> showModeChoice;
    SafePointer<Label> showModeStatus;
    SafePointer<Label> scanningPlugin;
    uint64 pluginRevision = ~uint64(0);
    std::unique_ptr<FileChooser> pluginFolderChooser;
    void timerCallback() override {
        if (selected == 1) {
            if (audioPageLocked != audioConfigurationLocked()) select(1);
            return;
        }
        if (selected == 0 && showModeChoice && showModeStatus) {
            showModeChoice->setEnabled(!showMode->busy && showMode->loaded);
            showModeChoice->setSelectedId(showMode->enabled ? 2 : 1, dontSendNotification);
            showModeStatus->setText(showMode->busy ? localization::translate(String::fromUTF8("Aguarde…")) : localization::translate(showMode->error), dontSendNotification);
            showModeStatus->setColour(Label::textColourId, showMode->error.isEmpty() ? theme::secondary : Colour(0xffff454a));
            return;
        }
        if (selected == 5) { updatePlugins(); return; }
        if (selected != 6 || !accountLogin) return;
        accountLogin->setEnabled(!auth.busy && !locked());
        accountLogout->setEnabled(!auth.busy && !locked() && auth.loginData.isObject());
        accountLogout->setButtonText(auth.busy ? localization::translate(String::fromUTF8("Aguarde…")) : localization::translate("Sair e liberar dispositivo"));
        accountTitle->setText(auth.title, dontSendNotification);
        accountEmail->setText(str(get(auth.loginData, "account"), "email"), dontSendNotification);
        accountEmail->setVisible(auth.loginData.isObject() && str(get(auth.loginData, "entitlement"), "planId") != "trial");
        accountMessage->setText(auth.message, dontSendNotification);
        updateDevices();
    }
    bool audioConfigurationLocked() const { return locked(); }
    bool locked() const {
        return session.transport().playing || session.transport().subPlay.playing ||
               session.audio.isRecording();
    }
    class DeviceAccountCard final : public Component {
      public:
        DeviceAccountCard(var value, bool thisComputer, std::function<void()> action)
            : device(std::move(value)), current(thisComputer), remove(localization::translate("Remover")) {
            setName(str(device, "deviceName"));
            addAndMakeVisible(remove);
            remove.getProperties().set("fontSize", 12.f);
            remove.getProperties().set("flat", true);
            remove.setColour(TextButton::buttonColourId, Colours::transparentBlack);
            remove.setColour(TextButton::textColourOffId, Colour(0xffff6868));
            remove.onClick = std::move(action);
        }
        void paint(Graphics &g) override {
            g.setColour(theme::panel);
            g.fillRoundedRectangle(getLocalBounds().toFloat(), 8.f);
            g.setColour(Colours::white.withMultipliedAlpha(isEnabled() ? 1.f : .35f));
            const float iconY = (getHeight() - 18.f) / 2.f;
            const bool desktop = str(device, "platform") == "macOS";
            g.drawRoundedRectangle(12.f, iconY, 25.f, 16.f, 2.f, 1.5f);
            if (desktop) {
                g.drawLine(24.5f, iconY + 16.f, 24.5f, iconY + 21.f, 1.5f);
                g.drawLine(18.5f, iconY + 21.f, 30.5f, iconY + 21.f, 1.5f);
            } else {
                g.drawLine(9.f, iconY + 19.f, 40.f, iconY + 19.f, 1.5f);
                g.drawLine(9.f, iconY + 19.f, 12.f, iconY + 16.f, 1.5f);
                g.drawLine(37.f, iconY + 16.f, 40.f, iconY + 19.f, 1.5f);
            }
            const int textWidth = std::max(0, remove.getX() - 60);
            g.setFont(theme::font(13.f, true));
            g.drawText(str(device, "deviceName"), 49, 11, textWidth, 22, Justification::centredLeft, true);
            g.setColour(theme::secondary.withMultipliedAlpha(isEnabled() ? 1.f : .35f));
            g.setFont(theme::font(11.f));
            g.drawText(str(device, "platform") + (current ? String::fromUTF8(" · ") + localization::translate("Este computador") : String()),
                       49, 35, textWidth, 17, Justification::centredLeft, true);
            const auto lastSeen = Time::fromISO8601(str(device, "lastSeenAt"));
            g.setFont(theme::font(10.f));
            g.drawText(localization::translate(String::fromUTF8("Último acesso:")) + " " +
                           (lastSeen.toMilliseconds() > 0 ? lastSeen.formatted("%d/%m/%Y %H:%M") : String::fromUTF8("—")),
                       49, 55, textWidth, 16, Justification::centredLeft, true);
        }
        void resized() override { remove.setBounds(getWidth() - 99, (getHeight() - 28) / 2, 87, 28); }
      private:
        var device;
        bool current;
        TextButton remove;
    };
    void layoutAccount() {
        if (!accountLogin || !accountTitle || !accountEmail || !accountLogout || !accountMessage) return;
        const int width = std::max(0, page.getWidth() - 48);
        accountTitle->setBounds(24, 66, width, 22);
        accountEmail->setBounds(24, 108, width, 20);
        accountLogin->setBounds(24, accountEmail->isVisible() ? 148 : 108, 190, 40);
        accountMessage->setSize(width, accountMessage->getHeight());
        for (auto *field : deviceFields)
            if (dynamic_cast<DeviceAccountCard *>(field) || dynamic_cast<Label *>(field))
                field->setSize(width, field->getHeight());
    }
    void updatePlugins() {
        auto &catalog = VST3Catalog::shared();
        if (catalog.revision == pluginRevision) {
            if (scanningPlugin) { scanningPlugin->setText(catalog.progressText(),dontSendNotification); scanningPlugin->setTooltip(catalog.currentPlugin); }
            return;
        }
        pluginRevision = catalog.revision; deviceFields.clear();
        auto addLabel = [this](String value,int y,int height=26) {
            auto *field=new Label();deviceFields.add(field);page.addAndMakeVisible(field);
            field->setText(value,dontSendNotification);field->setFont(theme::font(12));field->setBounds(24,y,526,height);
            field->setColour(Label::textColourId,theme::secondary);
        };
        auto addButton = [this](String title,int x,int y,int width,std::function<void()> click) {
            auto *button=new TextButton(title);deviceFields.add(button);page.addAndMakeVisible(button);
            button->setBounds(x,y,width,30);button->getProperties().set("flat",true);button->onClick=std::move(click);
            button->setEnabled(!VST3Catalog::shared().scanning);
        };
        addLabel("Caminhos VST3",66);int y=106;
        for (const auto &path : catalog.paths) {
            addLabel(path,y,38);
            addButton("Remover",550,y,86,[path] { VST3Catalog::shared().removePath(path); });y+=50;
        }
        addButton("Adicionar caminho",24,y,166,[safe=SafePointer<SettingsPanel>(this)] {
            if (!safe) return;
            safe->pluginFolderChooser=std::make_unique<FileChooser>("Adicionar caminho VST3",File("C:\\Program Files\\Common Files\\VST3"));
            safe->pluginFolderChooser->launchAsync(FileBrowserComponent::openMode|FileBrowserComponent::canSelectDirectories,
                [safe](const FileChooser &chooser) {
                    if(safe && chooser.getResult().isDirectory()) VST3Catalog::shared().addPath(chooser.getResult());
                });
        });
        addButton(catalog.scanning?"Cancelar escaneamento":"Escanear plugins",204,y,180,[] { auto &catalog=VST3Catalog::shared(); if(catalog.scanning)catalog.cancelScan();else catalog.scan(); });
        deviceFields.getLast()->setEnabled(true);
        if (catalog.hasFailedPlugins())
            addButton("Tentar falhas",398,y,148,[] { VST3Catalog::shared().scan(true); });
        y+=44;
        addLabel(catalog.status,y,64);y+=72;
        if (catalog.scanning) {
            auto *label = new Label(); deviceFields.add(label); page.addAndMakeVisible(label); scanningPlugin = label;
            label->setText(catalog.progressText(),dontSendNotification); label->setFont(theme::font(12));
            label->setColour(Label::textColourId,theme::secondary); label->setBounds(24,y,580,26); y+=32;
            auto *bar = new ProgressBar(catalog.scanProgress); deviceFields.add(bar); page.addAndMakeVisible(bar);
            bar->setBounds(24,y,580,16); bar->setPercentageDisplay(false); y+=36;
        }
        contentHeight=y+36;localization::panel(page);resized();
    }
    void updateDevices() {
        const auto snapshot = JSON::toString(auth.devices) + JSON::toString(get(auth.loginData, "entitlement")) +
                              String((int)auth.busy) + String((int)locked()) + String((int)accountEmail->isVisible()) + auth.message;
        if (snapshot == deviceSnapshot) return;
        deviceSnapshot = snapshot;
        deviceFields.clear();
        Array<var> active;
        for (const auto &device : list(auth.devices))
            if (str(device, "status") == "active") active.add(device);
        auto *count = new Label(); deviceFields.add(count); page.addAndMakeVisible(count);
        count->setText(String(active.size()) + " / " + String((int)get(get(auth.loginData, "entitlement"), "maxDevices", 4)) + " dispositivos", dontSendNotification);
        count->setFont(theme::font(11.f));
        count->setColour(Label::textColourId, theme::secondary);
        const int countTop = accountEmail->isVisible() ? 208 : 168;
        count->setBounds(24, countTop, 480, 16);
        int y = countTop + 36;
        for (const auto &device : active) {
            const auto installation = str(device, "installationId");
            const bool current = installation.equalsIgnoreCase(auth.installationId);
            auto *card = new DeviceAccountCard(device, current, [safe = SafePointer<SettingsPanel>(this), installation, current, name = str(device, "deviceName")] {
                if (!safe) return;
                AlertWindow::showOkCancelBox(MessageBoxIconType::QuestionIcon, "Remover dispositivo?", current
                    ? String::fromUTF8("Você sairá da conta neste computador e a licença ficará disponível.")
                    : "Remover " + name + " e liberar sua licença para outro computador?", "Remover", "Cancelar",
                    safe.getComponent(), ModalCallbackFunction::create([safe, installation](int accepted) { if (safe && accepted) safe->auth.removeDevice(installation); }));
            });
            deviceFields.add(card); page.addAndMakeVisible(card);
            card->setBounds(24, y, 580, 86);
            card->setEnabled(!auth.busy && (!current || !locked()));
            y += 106;
        }
        auto *refresh = new TextButton("Atualizar dispositivos"); deviceFields.add(refresh); page.addAndMakeVisible(refresh);
        refresh->setBounds(24, y, 184, 26); refresh->getProperties().set("flat", true);
        refresh->getProperties().set("fontSize", 12.f);
        refresh->setEnabled(!auth.busy && auth.loginData.isObject());
        refresh->onClick = [this] { auth.refreshDevices(); };
        accountLogout->setBounds(24, y + 46, 232, 40);
        accountMessage->setBounds(24, y + 106, 580, auth.message.isEmpty() ? 0 : 64);
        contentHeight = y + (auth.message.isEmpty() ? 110 : 194);
        localization::panel(page); resized();
    }
    Label &label(String title, int y, int height = 26, bool bold = false,
                 Colour colour = Colours::white) {
        auto *field = new Label();
        fields.add(field);
        page.addAndMakeVisible(field);
        field->setText(title, dontSendNotification);
        field->setFont(theme::font(bold ? 14.f : 13.f, bold));
        field->setColour(Label::textColourId, colour);
        field->setBounds(24, y, 710, height);
        return *field;
    }
    TextButton &button(String title, int x, int y, int width, std::function<void()> action) {
        auto *field = new TextButton(title);
        fields.add(field);
        page.addAndMakeVisible(field);
        field->setBounds(x, y, width, 34);
        field->getProperties().set("flat", true);
        field->onClick = std::move(action);
        return *field;
    }
    ComboBox &choice(String name, StringArray items, int current, int x, int y, int width,
                     std::function<void(int)> action) {
        auto *field = new ComboBox();
        fields.add(field);
        page.addAndMakeVisible(field);
        field->setName(name);
        field->setComponentID(name);
        field->addItemList(items, 1);
        field->setSelectedId(current, dontSendNotification);
        field->setBounds(x, y, width, 26);
        field->onChange = [field, action] { action(field->getSelectedId()); };
        return *field;
    }
    void refreshLater() {
        Timer::callAfterDelay(1, [safe = SafePointer<SettingsPanel>(this)] {
            if (safe)
                safe->select(safe->selected);
        });
    }
    void saveAudio() {
        if (auto xml = session.audio.devices.createStateXml()) {
            session.audio.systemDefaults.write(*xml);
            auto file = auth.dataDirectory().getChildFile("audio-device.xml");
            file.getParentDirectory().createDirectory();
            if (!xml->writeTo(file))
                error(String::fromUTF8("Não foi possível salvar a configuração de áudio."));
        }
    }
    void applyAudio(std::function<void(AudioDeviceManager::AudioDeviceSetup &)> change) {
        if (audioConfigurationLocked()) {
            error(String::fromUTF8("Conclua a gravação antes de alterar o dispositivo de áudio."));
            return;
        }
        auto setup = session.audio.devices.getAudioDeviceSetup();
        change(setup);
        const auto result = session.audio.devices.setAudioDeviceSetup(setup, true);
        if (result.isNotEmpty())
            error(result);
        else {
            // A missing device at launch has no callback yet. Attach it when
            // the user explicitly selects an available output.
            const auto opened = session.audio.openDevice();
            if (opened.isNotEmpty()) error(opened); else saveAudio();
        }
        refreshLater();
    }
    void select(int index) {
        selected = index;
        localization::english = preferences.value("jaras.language", "pt-BR").toString() == "en";
        actionPage = nullptr;
        deviceFields.clear(); deviceSnapshot.clear();
        fields.clear();
        viewport.setScrollBarsShown(index != 6, index != 6, index == 6, false);
        contentHeight = std::max(450, getHeight());
        for (int i = 0; i < tabs.size(); ++i)
            tabs[i]->setToggleState(i == index, dontSendNotification);
        auto &title = label(tabs[index]->getButtonText(), 20, 30, true);
        title.setFont(theme::font(18, true));
        if (index == 0) {
            contentHeight = 510;
            label(String::fromUTF8("Escala da interface"), 152, 26, true);
            StringArray scales;
            for (int percent = 75; percent <= 125; percent += 25) scales.add(String(percent) + "%");
            choice("interfaceScale", scales, roundToInt(preferences.interfaceScale() * 4) - 2, 24, 188, 176,
                   [this](int choice) {
                       auto result = preferences.set("jaras.interface.scale", (choice + 2) / 4.0);
                       if (result.failed()) error(result.getErrorMessage());
                   });
            label(localization::translate("Show Mode"), 240, 26, true);
            showModeChoice = &choice("showMode", {"Disabled", "Enabled"}, showMode->enabled ? 2 : 1, 24, 276, 176,
                [this](int id) { showMode->setEnabled(id == 2); timerCallback(); });
            auto &description = label(localization::translate("When enabled, the notebook lid can be closed without stopping playback."), 310, 48, false, theme::secondary);
            description.setFont(theme::font(11));
            showModeStatus = &label({}, 366, 38, false, theme::secondary);
            showModeStatus->setFont(theme::font(11));
            showMode->refresh(); timerCallback();
            label(localization::translate("Startup sound"), 410, 26, true);
            choice("startupSound", {"Disabled", "Enabled"}, (bool)preferences.value("jaras.startup.sound", true) ? 2 : 1,
                   24, 446, 176, [this](int id) {
                       auto result = preferences.set("jaras.startup.sound", id == 2);
                       if (result.failed()) error(result.getErrorMessage());
                   });
            label(localization::translate("Idioma"), 66, 26, true);
            for (int language = 0; language < 2; ++language) {
                auto &b = button(language == 0 ? "English" : String::fromUTF8("Português"),
                                 24 + language * 88, 106, 88, [this, language] {
                                     auto result = preferences.set("jaras.language",
                                                                   language == 0 ? "en" : "pt-BR");
                                     if (result.failed())
                                         error(result.getErrorMessage());
                                     refreshLater();
                                 });
                b.setToggleState(preferences.value("jaras.language", "pt-BR").toString() ==
                                     (language == 0 ? "en" : "pt-BR"),
                                 dontSendNotification);
                b.setBounds(24 + language * 88, 102, 88, 24);
                b.getProperties().set("fontSize", 13.f);
                b.setColour(TextButton::buttonOnColourId, Colour(0xff64b64a));
                b.setColour(TextButton::textColourOnId, Colours::white);
            }
        } else if (index == 1)
            audioPage();
        else if (index == 2)
            midiPage();
        else if (index == 3 || index == 4) {
            actionPage = new ActionsPage(actions, index == 4, [this](int number) {
                if (number <= 0)
                    return String("Pista selecionada");
                if (const auto *song = session.song())
                    if (const auto *track = actionTrack(*song, {}, number))
                        return text(track->name);
                return String::fromUTF8("Pista indisponível");
            });
            fields.add(actionPage);
            page.addAndMakeVisible(actionPage);
            contentHeight = std::max(450, getHeight());
        } else if (index == 5) {
            pluginRevision = ~uint64(0); updatePlugins();
        } else {
            accountTitle = &label(auth.title, 66, 26, true);
            accountTitle->setFont(theme::font(13.f, true));
            accountEmail = &label(str(get(auth.loginData, "account"), "email"), 104, 26, false, theme::secondary);
            auto &signin = button("Login / Trocar conta", 24, 146, 190, login);
            accountLogin = &signin;
            signin.getProperties().set("fontSize", 13.f);
            signin.getProperties().set("cornerRadius", 6.f);
            signin.getProperties().set("flat", false);
            signin.getProperties().set("borderAlpha", .12f);
            signin.setColour(TextButton::buttonColourId, theme::panel.withAlpha(.45f));
            signin.setComponentID("settingsLogin");
            signin.setEnabled(!auth.busy && !locked());
            auto &logout =
                button(localization::translate("Sair e liberar dispositivo"), 24, 304, 210, [this] { auth.logout(); });
            accountLogout = &logout; logout.setComponentID("settingsLogout");
            logout.getProperties().set("fontSize", 13.f);
            logout.getProperties().set("cornerRadius", 6.f);
            logout.getProperties().set("flat", false);
            logout.getProperties().set("borderAlpha", .25f);
            logout.setColour(TextButton::buttonColourId, Colours::red.withAlpha(.45f));
            logout.setEnabled(!auth.busy && !locked());
            accountMessage = &label(auth.message, 354, 80, false, theme::yellow);
            accountMessage->setFont(theme::font(11.f));
            timerCallback();
            auth.refreshDevices();
        }
        viewport.setViewPosition(0, 0);
        localization::panel(*this);
        resized();
        repaint();
    }
    void audioPage() {
        audioPageLocked = audioConfigurationLocked();
        if (audioPageLocked) {
            label("Stop the transport before changing the audio device.", 76, 70, false, theme::yellow);
            return;
        }
        auto &manager = session.audio.devices;
        const auto setup = manager.getAudioDeviceSetup();
        StringArray types;
        for (auto *type : manager.getAvailableDeviceTypes())
            types.add(type->getTypeName());
        label("Driver", 66, 26, true);
        choice("Driver", types, types.indexOf(manager.getCurrentAudioDeviceType()) + 1, 24, 102,
               260,
               [this, types](int id) {
                   if (audioConfigurationLocked())
                       return;
                   session.audio.systemDefaults.input = session.audio.systemDefaults.output = false;
                   session.audio.devices.setCurrentAudioDeviceType(types[id - 1], true);
                   const auto opened = session.audio.openDevice();
                   if (opened.isNotEmpty()) error(opened); else saveAudio();
                   refreshLater();
               })
            .setEnabled(!audioConfigurationLocked());
        if (audioConfigurationLocked())
            label(String::fromUTF8("Conclua a gravação antes de alterar o dispositivo de áudio."),
                  136, 28, false, theme::yellow);
        auto *type = manager.getCurrentDeviceTypeObject();
        if (!type) {
            label(String::fromUTF8("Nenhum dispositivo de áudio disponível."), 166, 28,
                  false, theme::secondary);
            return;
        }
        // Opening a settings window uses the device manager's current catalog.
        // Hardware enumeration belongs to the explicit refresh action; rescanning
        // every page rebuild can stall device notifications during playback.
        auto inputNames = type->getDeviceNames(true), outputNames = type->getDeviceNames(false);
        const bool offersDefault = session.audio.systemDefaults.supported();
        if (offersDefault) {
            const auto title = localization::english ? String("System default") : String::fromUTF8("Padrão do sistema");
            inputNames.insert(0, title); outputNames.insert(0, title);
        }
        inputNames.insert(0, "None");
        outputNames.insert(0, "None");
        const bool loopback = manager.getCurrentAudioDeviceType() == "Windows Audio (Loopback)";
        label(String::fromUTF8(loopback ? "Capturar áudio da saída do Windows" : "Dispositivo de áudio — Entrada"), 172, 26, true);
        choice("Entrada", inputNames,
               offersDefault && session.audio.systemDefaults.input ? 2 : setup.inputDeviceName.isEmpty() ? 1 : inputNames.indexOf(setup.inputDeviceName) + 1,
               290, 210, 290,
               [this, inputNames, offersDefault](int id) {
                   session.audio.systemDefaults.input = offersDefault && id == 2;
                   const auto name = session.audio.systemDefaults.input ? session.audio.systemDefaults.deviceName(true) : id == 1 ? String() : inputNames[id - 1];
                   applyAudio([name](auto &s) {
                       s.inputDeviceName = name;
                       s.useDefaultInputChannels = false;
                       s.inputChannels.clear();
                       if (name.isNotEmpty())
                           s.inputChannels.setBit(0);
                   });
               })
            .setEnabled(!audioConfigurationLocked());
        label(String::fromUTF8("Dispositivo de áudio — Saída"), 256, 26, true);
        choice(String::fromUTF8("Saída"), outputNames,
               offersDefault && session.audio.systemDefaults.output ? 2 : setup.outputDeviceName.isEmpty() ? 1
                                                : outputNames.indexOf(setup.outputDeviceName) + 1,
               290, 294, 290,
               [this, outputNames, offersDefault](int id) {
                   session.audio.systemDefaults.output = offersDefault && id == 2;
                   const auto name = session.audio.systemDefaults.output ? session.audio.systemDefaults.deviceName(false) : id == 1 ? String() : outputNames[id - 1];
                   applyAudio([name](auto &s) {
                       s.outputDeviceName = name;
                       s.useDefaultOutputChannels = false; s.outputChannels.clear();
                       if (name.isNotEmpty()) s.outputChannels.setBit(0);
                   });
               })
            .setEnabled(!audioConfigurationLocked());
        auto *device = manager.getCurrentAudioDevice();
        label(device ? String(device->getActiveOutputChannels().countNumberOfSetBits()) +
                           String::fromUTF8(" canais de saída")
                     : String::fromUTF8("Nenhum dispositivo de áudio disponível."),
              332, 26, false, theme::secondary);
        if (device) {
            auto rates = device->getAvailableSampleRates();
            StringArray choices;
            int chosen = 1;
            for (int i = 0; i < rates.size(); ++i) {
                choices.add(String((int)rates[i]) + " Hz");
                if (std::abs(rates[i] - device->getCurrentSampleRate()) < 1)
                    chosen = i + 1;
            }
            label(localization::translate("Taxa de amostragem"), 374, 26, true);
            auto &rateChoice = choice("Taxa de amostragem", choices, chosen, 24, 412, 160, [this, rates](int id) {
                if (id > 0 && id <= rates.size())
                    applyAudio([rates, id](auto &s) { s.sampleRate = rates[id - 1]; });
            });
            rateChoice.setEnabled(!audioConfigurationLocked());
            rateChoice.setComponentID("audioSampleRate");
            auto sizes = device->getAvailableBufferSizes();
            choices.clear();
            chosen = 1;
            for (int i = 0; i < sizes.size(); ++i) {
                choices.add(String(sizes[i]) + " amostras");
                if (sizes[i] == device->getCurrentBufferSizeSamples())
                    chosen = i + 1;
            }
            label(localization::translate("Tamanho do buffer"), 456, 26, true);
            auto &bufferChoice = choice("Tamanho do buffer", choices, chosen, 24, 494, 180, [this, sizes](int id) {
                if (id > 0 && id <= sizes.size())
                    applyAudio([sizes, id](auto &s) { s.bufferSize = sizes[id - 1]; });
            });
            bufferChoice.setEnabled(!audioConfigurationLocked());
            bufferChoice.setComponentID("audioBufferSize");
            if (loopback)
                label(String::fromUTF8("Loopback: selecione nas entradas a saída usada pelos outros aplicativos.\nUse Monitor Off na pista para gravar sem devolver o sinal à saída."),
                      620, 56, false, theme::secondary);
            else if (manager.getCurrentAudioDeviceType() == "Windows Audio")
                label(String::fromUTF8("Modo compartilhado: o Windows define o buffer.\nPara outras opções, selecione baixa latência, modo exclusivo ou ASIO em Driver."),
                      620, 56, false, theme::secondary);
            if (device->hasControlPanel())
                button(String::fromUTF8("Painel do dispositivo"), 24, 686, 210, [this] {
                    if (audioConfigurationLocked()) return;
                    if (auto *current = session.audio.devices.getCurrentAudioDevice()) current->showControlPanel();
                    refreshLater();
                }).setEnabled(!audioConfigurationLocked());
        }
        label(String::fromUTF8("Buffers menores reduzem a latência e usam mais CPU."), 534, 26,
              false, theme::secondary);
        button(localization::translate("Atualizar dispositivos"), 24, 574, 190, [this] {
            if (auto *current = session.audio.devices.getCurrentDeviceTypeObject()) current->scanForDevices();
            refreshLater();
        });
        contentHeight = 740;
    }
    void midiPage() {
        const auto inputs = MidiInput::getAvailableDevices(),
                   outputs = MidiOutput::getAvailableDevices();
        label(localization::translate("Entradas MIDI"), 66, 26, true);
        if (inputs.isEmpty())
            label(localization::translate("Nenhuma entrada MIDI"), 104, 26, false, theme::secondary);
        StringArray choices{"Nenhum"};
        for (const auto &device : inputs)
            choices.add(device.name);
        for (int slot = 0; slot < 6; ++slot) {
            const auto key = "catlive.midi.slot" + String(slot + 1);
            const auto current = preferences.value(key).toString();
            int selectedInput = 1;
            for (int i = 0; i < inputs.size(); ++i)
                if (inputs[i].identifier == current)
                    selectedInput = i + 2;
            label("MIDI " + String(slot + 1), 112 + slot * 42);
            choice("MIDI " + String(slot + 1), choices, selectedInput, 110, 112 + slot * 42, 350,
                   [this, inputs, key, slot](int id) {
                       const auto previous = preferences.value(key).toString();
                       const String next = id > 1 ? inputs[id - 2].identifier : String();
                       const auto result = preferences.set(key, next);
                       if (result.failed()) {
                           error(result.getErrorMessage());
                           return;
                       }
                       if (previous.isNotEmpty()) {
                           bool used = false;
                           for (int i = 1; i <= 6; ++i)
                               used |=
                                   preferences.value("catlive.midi.slot" + String(i)).toString() ==
                                   previous;
                           if (!used)
                               session.audio.devices.setMidiInputDeviceEnabled(previous, false);
                       }
                       if (next.isNotEmpty())
                           session.audio.devices.setMidiInputDeviceEnabled(next, true);
                       session.audio.setMIDISlot(slot, next);
                       saveAudio();
                   });
        }
        label(String::fromUTF8("Saídas MIDI"), 382, 26, true);
        choices = {"Nenhum"}; for (const auto &output : outputs) choices.add(output.name);
        for (int slot = 0; slot < 6; ++slot) {
            const auto key = "catlive.midi.outputSlot" + String(slot + 1);
            const auto current = preferences.value(key, slot == 0 ? session.audio.devices.getDefaultMidiOutputIdentifier() : String()).toString();
            int selected = 1; for (int i = 0; i < outputs.size(); ++i) if (outputs[i].identifier == current) selected = i + 2;
            label("MIDI " + String(slot + 1), 426 + slot * 42);
            choice("MIDI " + String(slot + 1), choices, selected, 110, 426 + slot * 42, 350,
                [this, outputs, key, slot](int id) {
                    const String next = id > 1 ? outputs[id-2].identifier : String();
                    const auto result = preferences.set(key,next); if (result.failed()) { error(result.getErrorMessage()); return; }
                    session.audio.setMIDIOutputSlot(slot,next);
                    if (slot == 0) session.audio.devices.setDefaultMidiOutputDevice(next);
                    saveAudio();
                });
        }
        button(localization::translate("Atualizar dispositivos"),24,700,190,[this]{refreshLater();});
        contentHeight = 760;
    }
};
} // namespace catlive
