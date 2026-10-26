#pragma once
#include "Localization.h"
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
            save[i].setButtonText(i == 0 ? "Salvar senha" : localization::translate("Salvar senha de Recados"));
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
        for(auto *button:{&search,&pair,&resume}) {
            addAndMakeVisible(*button);button->getProperties().set("fontSize",13.f);
        }
        search.setButtonText("Buscar na rede");pair.setButtonText("Solicitar pareamento");resume.setButtonText("Sincronizar novamente");
        addAndMakeVisible(computers);
        addAndMakeVisible(adapters);
        adapters.onChange=[this]{const int i=adapters.getSelectedItemIndex()-1;if(i>=0 && i<(int)cables.size())host.sync.chooseAdapter(cables[(size_t)i].hardware);else if(adapters.getSelectedId()==1)host.sync.chooseAdapter({});};
        for (auto *button : {&roleA,&roleB}) {
            addAndMakeVisible(*button); button->getProperties().set("fontSize",13.f);
            button->setClickingTogglesState(true); button->setRadioGroupId(108);
        }
        roleA.setButtonText("PC A");roleB.setButtonText("PC B");
        (host.sync.role=="B"?roleB:roleA).setToggleState(true,dontSendNotification);
        computers.setTextWhenNothingSelected("Selecione um computador");
        search.onClick=[this]{if(!host.enabled())toggleHost();host.sync.search();refresh();};
        pair.onClick=[this]{const auto i=computers.getSelectedItemIndex();if(i>=0 && i<(int)available.size())host.sync.request(available[(size_t)i],roleB.getToggleState()?"B":"A");refresh();};
        computers.onChange=[this]{refresh();};
        resume.onClick=[this]{host.sync.resume();refresh();};
        startTimerHz(4);
        refresh();
    }
    std::function<void()> layoutChanged;
    int preferredHeight() const { return contentHeight; }
    void resized() override {
        pins[0].setBounds(20, 198, getWidth() - 40, 28);
        save[0].setBounds(20, 278, 132, 28);
        pins[1].setBounds(20, 364, getWidth() - 40, 28);
        save[1].setBounds(20, 442, 210, 28);
        adapters.setBounds(20,644,getWidth()-40,28);
        int y=684;
        if(host.sync.paired()) y+=26;
        search.setBounds(20,y,160,28);y+=38;
        if(!available.empty()) {
            computerLabelY=y;y+=22;computers.setBounds(20,y,getWidth()-40,28);y+=38;
            roleLabelY=y;y+=22;
            const int width=(getWidth()-40)/2;
            roleA.setBounds(20,y,width,28);roleB.setBounds(20+width,y,getWidth()-40-width,28);y+=38;
            pair.setBounds(20,y,180,28);y+=38;
        }
        if(host.sync.paired()) {resume.setBounds(20,y,200,28);y+=38;}
        explanationY=y;y+=62;
        toggleButton.setBounds(20,y,166,30);contentHeight=y+50;
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
        label(localization::translate("Senha do modo Recados"), 338, 24, 14, Colours::white, true);
        label(localization::translate("Acesso apenas aos recados. Deixe vazio para entrar sem senha."), 404, 34, 12,
              theme::secondary);
        if (saved[1])
            label(String::fromUTF8("Configuração salva."), 474, 16, 11, theme::green);
        g.setColour(theme::line);g.drawHorizontalLine(496,20,(float)getWidth()-20);
        label("Project Sync",510,22,14,Colours::white,true);
        label(String::fromUTF8("Conecte os dois computadores por cabo Ethernet. O Remote do app continua disponível pelo Wi-Fi."),540,42,12,theme::secondary);
        label(host.sync.status,586,30,12,host.sync.following?theme::green:theme::secondary);
        label("Adaptador Ethernet",620,22,12);
        if(host.sync.paired())label("PC "+host.sync.role+String::fromUTF8(" · ")+host.sync.peerName,680,24,12,theme::secondary);
        if(!available.empty()) {label("Computador",computerLabelY,20,12);label("Este computador",roleLabelY,20,12);}
        label(String::fromUTF8("PC A controla o transporte. PC B continua tocando de forma independente se o A falhar."),explanationY,48,12,theme::secondary);
    }

  private:
    remote::Host &host;
    std::function<void()> toggleHost;
    TextEditor pins[2];
    TextButton save[2], toggleButton;
    bool saved[2]{};
    TextButton search,pair,resume,roleA,roleB;
    ComboBox computers,adapters;
    std::vector<remote::SyncEthernet::Interface> cables;
    int contentHeight=774,computerLabelY=0,roleLabelY=0,explanationY=0;
    std::vector<remote::SyncDiscovery::Peer> available;
    void timerCallback() override { refresh(); }
    void refresh() {
        toggleButton.setButtonText(host.enabled() ? localization::translate("Desativar Remote") : "Ativar Remote");
        const auto nextCables=host.sync.adapters();
        bool cableChange=nextCables.size()!=cables.size();
        if(!cableChange)for(size_t i=0;i<cables.size();++i)if(nextCables[i]!=cables[i] || nextCables[i].connected!=cables[i].connected || nextCables[i].name!=cables[i].name)cableChange=true;
        if(cableChange || adapters.getNumItems()==0) {
            cables=nextCables;adapters.clear(dontSendNotification);adapters.addItem(String::fromUTF8("Automático"),1);
            for(size_t i=0;i<cables.size();++i)adapters.addItem(cables[i].name+(cables[i].connected?String():String::fromUTF8(" · Desconectado")),int(i)+2);
        }
        const auto chosen=host.sync.selectedAdapter();int selected=1;
        for(size_t i=0;i<cables.size();++i)if(cables[i].hardware==chosen)selected=int(i)+2;
        if(!chosen.isEmpty() && selected==1){if(adapters.getNumItems()==(int)cables.size()+1)adapters.addItem("Adaptador desconectado",int(cables.size())+2);selected=int(cables.size())+2;}
        adapters.setSelectedId(selected,dontSendNotification);adapters.setEnabled(!host.sync.preparing());
        auto peers=host.sync.peers();
        bool different=peers.size()!=available.size();
        if(!different)for(size_t i=0;i<peers.size();++i)if(peers[i].id!=available[i].id || peers[i].name!=available[i].name)different=true;
        if(different) {
            const auto selected=computers.getSelectedItemIndex();
            const auto id=selected>=0 && selected<(int)available.size()?available[(size_t)selected].id:String();
            available=peers;computers.clear(dontSendNotification);
            for(size_t i=0;i<available.size();++i){computers.addItem(available[i].name,int(i)+1);if(available[i].id==id)computers.setSelectedId(int(i)+1,dontSendNotification);}
        } else available=peers;
        search.setEnabled(!host.sync.preparing());
        pair.setEnabled(computers.getSelectedId()>0 && !host.sync.following);
        computers.setVisible(!available.empty());roleA.setVisible(!available.empty());roleB.setVisible(!available.empty());pair.setVisible(!available.empty());
        resume.setVisible(host.sync.paired());
        const int oldHeight=contentHeight;resized();
        if(oldHeight!=contentHeight && layoutChanged)layoutChanged();
        repaint();
    }
};
class RemotePopover final : public Component {
public:
    RemotePopover(remote::Host &host,std::function<void()> toggle):panel(host,std::move(toggle)) {
        viewport.setViewedComponent(&panel,false);viewport.setScrollBarsShown(true,false);addAndMakeVisible(viewport);
        panel.layoutChanged=[this]{resized();};
    }
    ~RemotePopover() override {viewport.setViewedComponent(nullptr,false);}
    void resized() override {viewport.setBounds(getLocalBounds());panel.setSize(getWidth()-viewport.getScrollBarThickness(),panel.preferredHeight());}
private:
    RemotePanel panel;Viewport viewport;
};
} // namespace catlive
