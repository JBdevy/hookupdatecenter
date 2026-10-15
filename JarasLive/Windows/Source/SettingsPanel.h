#pragma once
#include "ActionsPage.h"
#include "Auth.h"
#include "Lighting.h"
namespace catlive {
class SettingsPanel final : public Component, private Timer {
  public:
    SettingsPanel(Session &s, Auth &a, Lighting &l, Appearance &p, ActionBindings &bindings,
                  int initial, std::function<void(String)> fail, std::function<void()> signIn)
        : session(s), auth(a), lighting(l), preferences(p), actions(bindings),
          error(std::move(fail)), login(std::move(signIn)) {
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
            tab->onClick = [this, i] { select(i); };
        }
        addAndMakeVisible(viewport);
        viewport.setViewedComponent(&page, false);
        viewport.setScrollBarsShown(true, true);
        select(initial);
        startTimerHz(4);
    }
    ~SettingsPanel() override { stopTimer(); }
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
    int selected = 0, contentHeight = 500;
    OwnedArray<TextButton> tabs;
    Viewport viewport;
    Component page;
    OwnedArray<Component> fields;
    ActionsPage *actionPage = nullptr;
    SafePointer<TextButton> accountLogin, accountLogout, accountValidate;
    SafePointer<Label> accountTitle, accountEmail, accountMessage;
    void timerCallback() override {
        if (selected != 6 || !accountLogin) return;
        accountLogin->setEnabled(!auth.busy && !locked());
        accountLogout->setEnabled(!auth.busy && !locked() && auth.loginData.isObject());
        accountValidate->setEnabled(!auth.busy && auth.loginData.isObject());
        accountLogout->setButtonText(auth.busy ? String::fromUTF8("Aguarde…") : "Sair e liberar dispositivo");
        accountTitle->setText(auth.title, dontSendNotification);
        accountEmail->setText(str(get(auth.loginData, "account"), "email"), dontSendNotification);
        accountMessage->setText(auth.message, dontSendNotification);
    }
    bool locked() const {
        return session.transport().playing || session.transport().subPlay.playing ||
               session.audio.isRecording();
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
            auto file = auth.dataDirectory().getChildFile("audio-device.xml");
            file.getParentDirectory().createDirectory();
            if (!xml->writeTo(file))
                error(String::fromUTF8("Não foi possível salvar a configuração de áudio."));
        }
    }
    void applyAudio(std::function<void(AudioDeviceManager::AudioDeviceSetup &)> change) {
        if (locked()) {
            error(String::fromUTF8("Pare o transporte antes de alterar o dispositivo de áudio."));
            return;
        }
        auto setup = session.audio.devices.getAudioDeviceSetup();
        change(setup);
        const auto result = session.audio.devices.setAudioDeviceSetup(setup, true);
        if (result.isNotEmpty())
            error(result);
        else
            saveAudio();
        refreshLater();
    }
    void select(int index) {
        selected = index;
        localization::english = preferences.value("jaras.language", "pt-BR").toString() == "en";
        actionPage = nullptr;
        fields.clear();
        contentHeight = std::max(450, getHeight());
        for (int i = 0; i < tabs.size(); ++i)
            tabs[i]->setToggleState(i == index, dontSendNotification);
        auto &title = label(tabs[index]->getButtonText(), 20, 30, true);
        title.setFont(theme::font(18, true));
        if (index == 0) {
            contentHeight = 150;
            label("Idioma", 66, 26, true);
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
            label("Plugins VST3", 66, 26, true);
            label(String::fromUTF8("Pasta de plugins"), 112);
            const auto folder = File::getSpecialLocation(File::commonApplicationDataDirectory)
                                    .getParentDirectory()
                                    .getChildFile("Program Files/Common Files/VST3");
            label(folder.getFullPathName(), 148, 26, false, theme::secondary);
            button("Abrir pasta", 24, 196, 140, [folder] { folder.revealToUser(); });
            label(String::fromUTF8(
                      "O carregamento de VST3 externo ainda não está disponível neste build."),
                  252, 56, false, theme::yellow);
        } else {
            accountTitle = &label(auth.title, 66, 26, true);
            accountEmail = &label(str(get(auth.loginData, "account"), "email"), 104, 26, false, theme::secondary);
            auto &signin = button("Login / Trocar conta", 24, 146, 190, login);
            accountLogin = &signin;
            signin.setComponentID("settingsLogin");
            signin.setEnabled(!auth.busy && !locked());
            label("Dispositivo: " + auth.deviceName, 194);
            accountValidate = &button("Validar agora", 24, 242, 150, [this] { auth.validate(); });
            auto &logout =
                button("Sair e liberar dispositivo", 24, 304, 210, [this] { auth.logout(); });
            accountLogout = &logout; logout.setComponentID("settingsLogout");
            logout.setColour(TextButton::buttonColourId, Colour(0xff8d3033));
            logout.setEnabled(!auth.busy && !locked());
            accountMessage = &label(auth.message, 354, 80, false, theme::yellow);
            timerCallback();
        }
        viewport.setViewPosition(0, 0);
        localization::panel(*this);
        resized();
        repaint();
    }
    void audioPage() {
        auto &manager = session.audio.devices;
        const auto setup = manager.getAudioDeviceSetup();
        StringArray types;
        for (auto *type : manager.getAvailableDeviceTypes())
            types.add(type->getTypeName());
        label("Driver", 66, 26, true);
        choice("Driver", types, types.indexOf(manager.getCurrentAudioDeviceType()) + 1, 24, 102,
               260,
               [this, types](int id) {
                   if (locked())
                       return;
                   session.audio.devices.setCurrentAudioDeviceType(types[id - 1], true);
                   saveAudio();
                   refreshLater();
               })
            .setEnabled(!locked());
        if (locked())
            label(String::fromUTF8("Pare o transporte antes de alterar o dispositivo de áudio."),
                  136, 28, false, theme::yellow);
        auto *type = manager.getCurrentDeviceTypeObject();
        if (!type || !manager.getCurrentAudioDevice()) {
            label(String::fromUTF8("Nenhum dispositivo de áudio disponível."), 166, 28,
                  false, theme::secondary);
            if (!type) return;
        }
        type->scanForDevices();
        auto inputNames = type->getDeviceNames(true), outputNames = type->getDeviceNames(false);
        inputNames.insert(0, "None");
        outputNames.insert(0, "None");
        label(String::fromUTF8("Dispositivo de áudio — Entrada"), 172, 26, true);
        choice("Entrada", inputNames,
               setup.inputDeviceName.isEmpty() ? 1 : inputNames.indexOf(setup.inputDeviceName) + 1,
               290, 210, 290,
               [this, inputNames](int id) {
                   applyAudio([id, inputNames](auto &s) {
                       s.inputDeviceName = id == 1 ? String() : inputNames[id - 1];
                       s.useDefaultInputChannels = false;
                       s.inputChannels.clear();
                       if (id != 1)
                           s.inputChannels.setRange(0, 2, true);
                   });
               })
            .setEnabled(!locked());
        label(String::fromUTF8("Dispositivo de áudio — Saída"), 256, 26, true);
        choice(String::fromUTF8("Saída"), outputNames,
               setup.outputDeviceName.isEmpty() ? 1
                                                : outputNames.indexOf(setup.outputDeviceName) + 1,
               290, 294, 290,
               [this, outputNames](int id) {
                   applyAudio([id, outputNames](auto &s) {
                       s.outputDeviceName = id == 1 ? String() : outputNames[id - 1];
                       s.useDefaultOutputChannels = true;
                   });
               })
            .setEnabled(!locked());
        auto *device = manager.getCurrentAudioDevice();
        label(device ? String(device->getActiveOutputChannels().countNumberOfSetBits()) +
                           String::fromUTF8(" canais de saída")
                     : String::fromUTF8("Nenhum dispositivo de saída"),
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
            label("Taxa de amostragem", 374, 26, true);
            auto &rateChoice = choice("Taxa de amostragem", choices, chosen, 24, 412, 160, [this, rates](int id) {
                if (id > 0 && id <= rates.size())
                    applyAudio([rates, id](auto &s) { s.sampleRate = rates[id - 1]; });
            });
            rateChoice.setEnabled(!locked());
            rateChoice.setComponentID("audioSampleRate");
            auto sizes = device->getAvailableBufferSizes();
            choices.clear();
            chosen = 1;
            for (int i = 0; i < sizes.size(); ++i) {
                choices.add(String(sizes[i]) + " amostras");
                if (sizes[i] == device->getCurrentBufferSizeSamples())
                    chosen = i + 1;
            }
            label("Tamanho do buffer", 456, 26, true);
            auto &bufferChoice = choice("Tamanho do buffer", choices, chosen, 24, 494, 180, [this, sizes](int id) {
                if (id > 0 && id <= sizes.size())
                    applyAudio([sizes, id](auto &s) { s.bufferSize = sizes[id - 1]; });
            });
            bufferChoice.setEnabled(!locked());
            bufferChoice.setComponentID("audioBufferSize");
            if (manager.getCurrentAudioDeviceType() == "Windows Audio")
                label(String::fromUTF8("Modo compartilhado: o Windows define o buffer.\nPara outras opções, selecione baixa latência, modo exclusivo ou ASIO em Driver."),
                      620, 56, false, theme::secondary);
            if (device->hasControlPanel())
                button(String::fromUTF8("Painel do dispositivo"), 24, 686, 210, [this] {
                    if (locked()) return;
                    if (auto *current = session.audio.devices.getCurrentAudioDevice()) current->showControlPanel();
                    refreshLater();
                }).setEnabled(!locked());
        }
        label(String::fromUTF8("Buffers menores reduzem a latência e usam mais CPU."), 534, 26,
              false, theme::secondary);
        button("Atualizar dispositivos", 24, 574, 190, [this] { refreshLater(); });
        button(String::fromUTF8("Canais de entrada e saída"), 230, 574, 230, [this] {
            auto selector = std::make_unique<AudioDeviceSelectorComponent>(
                session.audio.devices, 0, 32, 0, 32, false, false, true, false);
            selector->setSize(600, 420);
            CallOutBox::launchAsynchronously(
                std::move(selector), getScreenBounds().withSizeKeepingCentre(50, 20), nullptr);
        }).setEnabled(!locked());
        contentHeight = 740;
    }
    void midiPage() {
        const auto inputs = MidiInput::getAvailableDevices(),
                   outputs = MidiOutput::getAvailableDevices();
        label("Entradas MIDI", 66, 26, true);
        if (inputs.isEmpty())
            label("Nenhuma entrada MIDI", 104, 26, false, theme::secondary);
        StringArray choices{"Nenhum"};
        for (const auto &device : inputs)
            choices.add(device.name);
        for (int slot = 0; slot < 3; ++slot) {
            const auto key = "catlive.midi.slot" + String(slot + 1);
            const auto current = preferences.value(key).toString();
            int selectedInput = 1;
            for (int i = 0; i < inputs.size(); ++i)
                if (inputs[i].identifier == current)
                    selectedInput = i + 2;
            label("MIDI " + String(slot + 1), 154 + slot * 64);
            choice("MIDI " + String(slot + 1), choices, selectedInput, 110, 154 + slot * 64, 350,
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
                           for (int i = 1; i <= 3; ++i)
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
        label(String::fromUTF8("Saída MIDI"), 352, 26, true);
        choices = {"Nenhum"};
        int selectedOutput = 1;
        for (int i = 0; i < outputs.size(); ++i) {
            choices.add(outputs[i].name);
            if (outputs[i].identifier == session.audio.devices.getDefaultMidiOutputIdentifier())
                selectedOutput = i + 2;
        }
        choice(String::fromUTF8("Saída MIDI"), choices, selectedOutput, 24, 398, 430,
               [this, outputs](int id) {
                   session.audio.devices.setDefaultMidiOutputDevice(
                       id > 1 ? outputs[id - 2].identifier : String());
                   saveAudio();
               });
        if (outputs.isEmpty())
            label(String::fromUTF8("Nenhuma saída MIDI"), 442, 26, false, theme::secondary);
        button("Atualizar dispositivos", 24, 490, 190, [this] { refreshLater(); });
        contentHeight = 550;
    }
};
} // namespace catlive
