#pragma once
#include "ConfirmationPanel.h"
#include "Localization.h"
#include "ResolumeComposition.h"
#include "ModalSheet.h"
namespace catlive {
class ResolumePanel final : public Component {
  public:
    ResolumePanel(Session &owner, Lighting &light, std::function<void(String)> failure)
        : session(owner), lighting(light), error(std::move(failure)) {
        lighting.refresh();
        host.setText(lighting.host, false);
        osc.setText(String(lighting.port), false);
        web.setText(String(lighting.webPort), false);
        for (auto *editor : {&host, &osc, &web}) {
            addAndMakeVisible(editor);
            editor->setFont(theme::font(13));
            editor->setColour(TextEditor::backgroundColourId, theme::display);
        }
        osc.setInputRestrictions(5, "0123456789");
        web.setInputRestrictions(5, "0123456789");
        markers.setButtonText(localization::translate(String::fromUTF8("Incluir marcadores no mapa do Resolume")));
        markers.setToggleState(lighting.includeMarkers, dontSendNotification);
        follow.setButtonText(localization::translate("Acompanhar o transporte do CatLive"));
        follow.setToggleState(lighting.resolumeEnabled, dontSendNotification);
        for (auto *button :
             std::initializer_list<Button *>{&markers, &follow, &map, &create, &apply}) {
            addAndMakeVisible(button);
            button->setWantsKeyboardFocus(false);
        }
        map.onClick = [this] { saveMap(); };
        apply.onClick = [this] {
            if (saveMap())
                ModalSheet::dismiss(*this);
        };
        create.onClick = [this] { confirmCreate(); };
        apply.setColour(TextButton::buttonColourId, Colour(0xff69b83d));
        addAndMakeVisible(status);
        status.setFont(theme::font(12));
        status.setColour(Label::textColourId, theme::secondary);
        status.setJustificationType(Justification::topLeft);
    }
    ~ResolumePanel() override {
        cancelled->store(true);
        worker.removeAllJobs(true, 15000);
        if (busy)
            session.busy = false;
    }
    void paint(Graphics &g) override {
        g.fillAll(theme::background);
        g.setFont(theme::font(13));
        g.setColour(Colours::white);
        g.drawText(localization::translate(String::fromUTF8("Endereço")), 24, 18, 64, 26, Justification::centredLeft);
        g.drawText("OSC", 267, 18, 34, 26, Justification::centredLeft);
        g.drawText("Webserver", 381, 18, 77, 26, Justification::centredLeft);
        g.setColour(theme::secondary);
        g.setFont(theme::font(12));
        g.drawFittedText(
            String::fromUTF8("Ative OSC Input nas preferências do Resolume (porta 7000). Para "
                             "criar a composição automaticamente, ative o Webserver (porta 8080) "
                             "no Resolume Arena 7.22 ou mais recente."),
            24, 132, getWidth() - 48, 43, Justification::topLeft, 3);
        g.drawFittedText(
            String::fromUTF8("Antes de criar a composição, salve seu trabalho no Resolume e abra "
                             "uma composição nova e vazia. O CatLive cria um deck por música e uma "
                             "coluna por marcador. Depois, coloque seus vídeos nessas colunas."),
            24, 181, getWidth() - 48, 43, Justification::topLeft, 3);
        g.setColour(theme::line);
        g.drawHorizontalLine(getHeight() - 67, 24.f, (float)getWidth() - 24);
        g.setColour(theme::secondary);
        g.setFont(theme::font(10));
        g.drawText(
            String::fromUTF8(
                "O mapa e as configurações da conexão ficam salvos neste projeto do CatLive."),
            24, getHeight() - 49, getWidth() - 145, 28, Justification::centredLeft);
    }
    void resized() override {
        host.setBounds(90, 18, 170, 26);
        osc.setBounds(303, 18, 70, 26);
        web.setBounds(458, 18, 70, 26);
        markers.setBounds(20, 58, getWidth() - 40, 27);
        follow.setBounds(20, 93, getWidth() - 40, 27);
        map.setBounds(24, 232, 154, 26);
        create.setBounds(186, 232, 193, 26);
        status.setBounds(24, 275, getWidth() - 48, std::max(20, getHeight() - 350));
        apply.setBounds(getWidth() - 90, getHeight() - 48, 66, 26);
    }
    bool keyPressed(const KeyPress &key) override {
        if (key == KeyPress::returnKey && !busy) {
            apply.triggerClick();
            return true;
        }
        return false;
    }

  private:
    Session &session;
    Lighting &lighting;
    std::function<void(String)> error;
    TextEditor host, osc, web;
    ToggleButton markers, follow;
    TextButton map{localization::translate("Criar / atualizar mapa")},
        create{String::fromUTF8("Criar projeto do Resolume…")}, apply{"Aplicar"};
    Label status;
    std::unique_ptr<FileChooser> chooser;
    ThreadPool worker{1};
    std::shared_ptr<std::atomic<bool>> cancelled = std::make_shared<std::atomic<bool>>(false);
    bool busy = false;
    bool saveMap() {
        if (busy)
            return false;
        try {
            const int port = osc.getText().getIntValue(), webPort = web.getText().getIntValue();
            ResolumeComposition::network(host.getText(), webPort);
            if (port < 1 || port > 65535)
                throw std::runtime_error("Porta OSC inválida.");
            lighting.host = host.getText().trim();
            lighting.port = port;
            lighting.webPort = webPort;
            lighting.includeMarkers = markers.getToggleState();
            lighting.enableResolume(follow.getToggleState());
            lighting.refresh();
            if (lighting.resolumeEnabled && !lighting.connectResolume())
                throw std::runtime_error(utf8(lighting.error));
            lighting.saveSettings();
            status.setText(
                String::fromUTF8(
                    "Mapa Resolume atualizado. Salve o projeto CatLive para manter as alterações."),
                dontSendNotification);
            return true;
        } catch (const std::exception &e) {
            status.setText(String::fromUTF8(e.what()), dontSendNotification);
            return false;
        }
    }
    void confirmCreate() {
        if (busy || !saveMap())
            return;
        auto safe = SafePointer<ResolumePanel>(this);
        ConfirmationPanel::show(MessageBoxIconType::QuestionIcon,
            String::fromUTF8("Criar composição do Resolume?"),
            String::fromUTF8("Abra uma composição nova e vazia no Resolume primeiro. Composições que contêm mídia não serão substituídas."),
            "Criar", "Cancelar", this, ModalCallbackFunction::create([safe](int result) {
                if(safe && result) safe->chooseDestination();
            }));
    }
    void chooseDestination() {
        chooser = std::make_unique<FileChooser>(
            String::fromUTF8("Salvar composição Resolume"),
            session.mediaDirectory.getChildFile(
                Lighting::safeStem(Lighting::cleanName(text(session.project().name), "Projeto CatLive")) + ".avc"),
            "*.avc");
        auto safe = SafePointer<ResolumePanel>(this);
        chooser->launchAsync(
            FileBrowserComponent::saveMode | FileBrowserComponent::warnAboutOverwriting,
            [safe](const FileChooser &picker) {
                if (safe && picker.getResult() != File())
                    safe->createComposition(picker.getResult().withFileExtension("avc"));
            });
    }
    void setBusy(bool value) {
        busy = value;
        session.busy = value;
        for (auto *child : getChildren())
            child->setEnabled(!value);
        status.setEnabled(true);
        ModalSheet::blockDismiss(*this, value);
    }
    void createComposition(const File &file) {
        try {
            auto plan = ResolumeComposition::plan(lighting, text(session.project().name));
            auto request = ResolumeComposition::network(lighting.host, lighting.webPort);
            auto safe = SafePointer<ResolumePanel>(this);
            auto cancel = cancelled;
            const bool following = lighting.resolumeEnabled;
            lighting.enableResolume(false);
            setBusy(true);
            status.setText(String::fromUTF8("Criando composição no Resolume…"),
                           dontSendNotification);
            worker.addJob([safe, cancel, plan = std::move(plan), request = std::move(request), file,
                           following] {
                String failure;
                try {
                    ResolumeComposition client(
                        request, [cancel] { return cancel->load(); },
                        [safe](String progress) {
                            MessageManager::callAsync([safe, progress] {
                                if (safe)
                                    safe->status.setText(progress, dontSendNotification);
                            });
                        });
                    client.create(plan, file);
                } catch (const std::exception &e) {
                    failure = String::fromUTF8(e.what());
                }
                MessageManager::callAsync([safe, failure, following] {
                    if (!safe)
                        return;
                    safe->lighting.enableResolume(following);
                    if (following)
                        safe->lighting.connectResolume();
                    safe->setBusy(false);
                    safe->status.setText(
                        failure.isEmpty()
                            ? String::fromUTF8(
                                  "Composição criada. Coloque os vídeos nas colunas geradas.")
                            : failure,
                        dontSendNotification);
                });
            });
        } catch (const std::exception &e) {
            error(String::fromUTF8(e.what()));
        }
    }
};
} // namespace catlive
