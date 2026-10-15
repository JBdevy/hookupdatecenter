#pragma once
#include "RemoteHost.h"
namespace catlive {
class RemotePanel final : public Component, private Timer {
  public:
    RemotePanel(remote::Host &value, std::function<void()> toggle)
        : host(value), toggleHost(std::move(toggle)) {
        for (int i = 0; i < 2; ++i) {
            addAndMakeVisible(pins[i]);
            pins[i].setInputRestrictions(4, "0123456789");
            pins[i].setPasswordCharacter('*');
            pins[i].setText(host.pin(i == 1), false);
            pins[i].setTextToShowWhenEmpty(String::fromUTF8("4 dígitos · vazio para remover"),
                                           theme::secondary);
            pins[i].setFont(theme::font(13));
            addAndMakeVisible(save[i]);
            save[i].setButtonText(i == 0 ? "Salvar senha" : "Salvar senha de Recados");
            save[i].getProperties().set("fontSize", 13.f);
            save[i].getProperties().set("flat", true);
            save[i].onClick = [this, i] {
                saved[i] = host.savePIN(i == 1, pins[i].getText());
                repaint();
            };
            pins[i].onTextChange = [this, i] {
                saved[i] = false;
                save[i].setEnabled(remote::pinValid(pins[i].getText()));
                repaint();
            };
        }
        addAndMakeVisible(toggleButton);
        toggleButton.onClick = [this] {
            toggleHost();
            refresh();
        };
        toggleButton.getProperties().set("fontSize", 13.f);
        toggleButton.getProperties().set("flat", true);
        startTimerHz(4);
        refresh();
    }
    void resized() override {
        pins[0].setBounds(20, 198, getWidth() - 40, 28);
        save[0].setBounds(20, 278, 132, 28);
        pins[1].setBounds(20, 364, getWidth() - 40, 28);
        save[1].setBounds(20, 442, 210, 28);
        toggleButton.setBounds(20, 498, 166, 30);
    }
    void paint(Graphics &g) override {
        g.fillAll(theme::panel);
        auto label = [&](String text, int y, int height, float size = 13,
                         Colour color = Colours::white, bool bold = false) {
            g.setColour(color);
            g.setFont(theme::font(size, bold));
            g.drawFittedText(text, 20, y, getWidth() - 40, height, Justification::topLeft,
                             height > 28 ? 3 : 1);
        };
        label("Abra o Remote no iPad e escolha este computador.", 14, 40);
        label(host.status(), 58, 20, 12, host.enabled() ? theme::green : theme::secondary);
        label(host.peerNames(), 80, 18, 12, theme::secondary);
        label(
            String::fromUTF8("O áudio continua no PC. Conecte os dispositivos à mesma rede local."),
            104, 40, 12, theme::secondary);
        g.setColour(theme::line);
        g.drawHorizontalLine(148, 20, (float)getWidth() - 20);
        g.drawHorizontalLine(326, 20, (float)getWidth() - 20);
        label("Senha do modo Diretor", 162, 24, 14, Colours::white, true);
        label(String::fromUTF8("Deixe vazio e salve para entrar sem senha. Observadores entram sem "
                               "senha e não controlam o PC."),
              238, 36, 12, theme::secondary);
        if (saved[0])
            label(String::fromUTF8("Configuração salva."), 310, 16, 11, theme::green);
        label("Senha do modo Recados", 338, 24, 14, Colours::white, true);
        label("Acesso apenas aos recados. Deixe vazio para entrar sem senha.", 404, 34, 12,
              theme::secondary);
        if (saved[1])
            label(String::fromUTF8("Configuração salva."), 474, 16, 11, theme::green);
    }

  private:
    remote::Host &host;
    std::function<void()> toggleHost;
    TextEditor pins[2];
    TextButton save[2], toggleButton;
    bool saved[2]{};
    void timerCallback() override { refresh(); }
    void refresh() {
        toggleButton.setButtonText(host.enabled() ? "Desativar Remote" : "Ativar Remote");
        repaint();
    }
};
} // namespace catlive
