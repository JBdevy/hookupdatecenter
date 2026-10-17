#pragma once
#include "Session.h"
#include "ModalSheet.h"
namespace catlive {
class ExportPanel final : public Component, private ListBoxModel, private Timer {
  public:
    ExportPanel(Session &owner, ID track, ID clip, std::function<void(String)> failure, bool stems = false)
        : session(owner), error(std::move(failure)) {
        if (!track.empty())
            tracks.insert(track);
        if (!clip.empty())
            clips.insert(clip);
        if (session.transport().regionId)
            regions.insert(*session.transport().regionId);
        if (session.transport().loop.start && session.transport().loop.end &&
            *session.transport().loop.end > *session.transport().loop.start)
            area = std::make_pair(*session.transport().loop.start, *session.transport().loop.end);
        for (auto *box : {&source, &bounds, &format, &quality, &rate, &channels})
            addAndMakeVisible(box);
        source.addItemList({"Master", "Tracks", "Master + Tracks", "Stems"}, 1);
        source.setSelectedId(stems ? 4 : 1, dontSendNotification);
        bounds.addItemList({"Projeto completo", String::fromUTF8("Área selecionada"),
                            String::fromUTF8("Regiões selecionadas"),
                            String::fromUTF8("Todas as regiões")},
                           1);
        bounds.setSelectedId(1, dontSendNotification);
        source.onChange = [this] { rebuild(); };
        bounds.onChange = [this] { rebuild(); };
        addAndMakeVisible(directory);
        addAndMakeVisible(pattern);
        directory.setText((session.document == File()
                               ? File::getSpecialLocation(File::userDesktopDirectory)
                               : session.document.getParentDirectory())
                              .getFullPathName());
        pattern.setText("%project");
        pattern.onTextChange = [this] { rebuild(); };
        for (auto *field : {&directory, &pattern})
            field->setFont(theme::font(13));
        addAndMakeVisible(browse);
        browse.getProperties().set("icon", "folder");
        browse.onClick = [this] { chooseDirectory(); };
        for (const auto &token : StringArray{"%track", "%region", "%stem", "%project"}) {
            auto *button = tokens.add(new TextButton(token));
            addAndMakeVisible(button);
            button->getProperties().set("flat", true);
            button->onClick = [this, token] { pattern.insertTextAtCaret(token); };
        }
        addAndMakeVisible(files);
        files.setModel(this);
        files.setRowHeight(32);
        files.setColour(ListBox::backgroundColourId, Colour(0xff121212));
        addAndMakeVisible(primary);
        addAndMakeVisible(secondary);
        addAndMakeVisible(enableSecondary);
        primary.getProperties().set("flat", true);
        secondary.getProperties().set("flat", true);
        primary.onClick = [this] {
            selectedOutput = 0;
            updateEncoding();
        };
        secondary.onClick = [this] {
            selectedOutput = 1;
            updateEncoding();
        };
        enableSecondary.onClick = [this] {
            secondaryEnabled = enableSecondary.getToggleState();
            updateEncoding();
            rebuild();
        };
        format.addItemList({"WAV", "AIFF", "MP3"}, 1);
        format.onChange = [this] {
            if (updating)
                return;
            encodings[selectedOutput].format = format.getText();
            if (format.getText() == "MP3" && encodings[selectedOutput].rate > 48000)
                encodings[0].rate = encodings[1].rate = 48000;
            updateEncoding();
            rebuild();
        };
        quality.onChange = [this] {
            if (updating)
                return;
            if (encodings[selectedOutput].format == "MP3")
                encodings[selectedOutput].bitrate = quality.getSelectedId();
            else
                encodings[selectedOutput].bits = quality.getSelectedId();
            rebuild();
        };
        for (int r : {44100, 48000})
            rate.addItem(String(r / 1000., r % 1000 ? 1 : 0) + " kHz", r);
        rate.onChange = [this] {
            if (updating)
                return;
            encodings[0].rate = encodings[1].rate = rate.getSelectedId();
            rebuild();
        };
        channels.addItem("Mono", 1);
        channels.addItem(String::fromUTF8("Estéreo"), 2);
        channels.onChange = [this] {
            if (updating)
                return;
            encodings[0].channels = encodings[1].channels = channels.getSelectedId();
            rebuild();
        };
        addAndMakeVisible(renderButton);
        renderButton.setColour(TextButton::buttonColourId, theme::green);
        renderButton.setColour(TextButton::textColourOffId, Colours::black);
        renderButton.getProperties().set("flat", true);
        renderButton.onClick = [this] {
            if (rendering && session.busy) {
                session.cancelExport();
                return;
            }
            start();
        };
        updateEncoding();
        rebuild();
        startTimerHz(8);
    }
    void selectRegions(std::set<ID> ids) {
        regions = std::move(ids); tracks.clear(); clips.clear();
        bounds.setSelectedId(3, dontSendNotification); pattern.setText("%region", false); rebuild();
    }
    ~ExportPanel() override {
        stopTimer();
        files.setModel(nullptr);
    }
    var diagnostics() const {
        auto value=object();put(value,"jobs",(int)jobs.size());put(value,"source",source.getSelectedId());
        put(value,"bounds",bounds.getSelectedId());put(value,"secondary",secondaryEnabled);
        put(value,"primaryFormat",encodings[0].format);put(value,"secondaryFormat",encodings[1].format);
        return value;
    }
    void paint(Graphics &g) override {
        g.fillAll(theme::panel);
        g.setColour(Colours::white);
        g.setFont(theme::font(13));
        auto label = [&](String text, int x, int y, int width) {
            g.drawText(text, x, y, width, 26, Justification::centredLeft);
        };
        label("Origem", 20, 12, 52);
        label("Limites", 232, 12, 52);
        g.setColour(theme::secondary);
        g.setFont(theme::font(10));
        g.drawText(String((int)jobs.size()) + " arquivos", getWidth() - 130, 12, 110, 26,
                   Justification::centredRight);
        g.setColour(Colour(0xff2b2b2b));
        g.fillRoundedRectangle(20, 66, getWidth() - 40.f, 92, 10);
        g.setColour(Colours::white);
        g.setFont(theme::font(13));
        label(String::fromUTF8("Diretório:"), 34, 80, 130);
        label("Nome do arquivo:", 34, 116, 130);
        g.setColour(Colour(0xff151515));
        g.fillRoundedRectangle(20, getHeight() - 128.f, 420, 78, 5);
        g.setColour(Colours::white);
        g.setFont(theme::font(12));
        const int formatY = getHeight() - 81;
        label("Formato", 30, formatY, 58);
        label(encodings[selectedOutput].format == "MP3" ? "Taxa de bits" : "Bits", 174, formatY,
              78);
        g.setFont(theme::font(10));
        label("Taxa de amostragem", 20, getHeight() - 36, 110);
        label("Canais", 240, getHeight() - 36, 48);
        if (rendering || status.isNotEmpty()) {
            g.setColour(session.busy ? theme::green : theme::secondary);
            g.setFont(theme::font(11));
            g.drawFittedText(session.busy ? String::fromUTF8("Renderizando… ") +
                                                String(session.importProgress * 100, 0) + "%"
                                          : status,
                             460, getHeight() - 112, getWidth() - 480, 64,
                             Justification::centredLeft, 3);
        }
    }
    void resized() override {
        source.setBounds(72, 12, 140, 26);
        bounds.setBounds(284, 12, 180, 26);
        directory.setBounds(164, 80, getWidth() - 246, 27);
        browse.setBounds(getWidth() - 76, 80, 48, 27);
        pattern.setBounds(164, 116, getWidth() - 192, 26);
        int x = 20;
        for (auto *button : tokens) {
            button->setBounds(x, 170, 72, 23);
            x += 80;
        }
        files.setBounds(20, 204, getWidth() - 40, std::max(40, getHeight() - 346));
        primary.setBounds(30, getHeight() - 118, 198, 24);
        secondary.setBounds(228, getHeight() - 118, 202, 24);
        enableSecondary.setBounds(455, getHeight() - 118, 260, 24);
        format.setBounds(90, getHeight() - 81, 76, 25);
        quality.setBounds(252, getHeight() - 81, 104, 25);
        rate.setBounds(132, getHeight() - 36, 100, 25);
        channels.setBounds(292, getHeight() - 36, 90, 25);
        renderButton.setBounds(getWidth() - 110, getHeight() - 36, 90, 25);
    }

  private:
    Session &session;
    std::function<void(String)> error;
    std::set<ID> tracks, clips, regions;
    std::optional<std::pair<double, double>> area;
    ComboBox source, bounds, format, quality, rate, channels;
    TextEditor directory, pattern;
    TextButton browse, primary{String::fromUTF8("Formato de saída principal")},
        secondary{String::fromUTF8("Formato de saída secundária")}, renderButton{"Renderizar"};
    ToggleButton enableSecondary{String::fromUTF8("Ativar saída secundária")};
    OwnedArray<TextButton> tokens;
    ListBox files;
    std::vector<ExportJob> jobs;
    ExportEncoding encodings[2];
    int selectedOutput = 0;
    bool updating = false, secondaryEnabled = false, rendering = false;
    String status;
    std::unique_ptr<FileChooser> chooser;
    void updateEncoding() {
        updating = true;
        const auto &encoding = encodings[selectedOutput];
        primary.setColour(TextButton::buttonColourId,
                          selectedOutput == 0 ? Colour(0xff63b641) : Colour(0xff292929));
        secondary.setColour(TextButton::buttonColourId,
                            selectedOutput == 1 ? Colour(0xff63b641) : Colour(0xff292929));
        enableSecondary.setVisible(selectedOutput == 1);
        enableSecondary.setToggleState(secondaryEnabled, dontSendNotification);
        format.setSelectedId(encoding.format == "WAV"    ? 1
                             : encoding.format == "AIFF" ? 2
                                                         : 3,
                             dontSendNotification);
        quality.clear(dontSendNotification);
        if (encoding.format == "MP3")
            for (int value : {64, 96, 128, 160, 192, 224, 256, 320})
                quality.addItem(String(value) + " kbps", value);
        else
            for (int value : {16, 24, 32})
                quality.addItem(String(value) + " bits", value);
        quality.setSelectedId(encoding.format == "MP3" ? encoding.bitrate : encoding.bits,
                              dontSendNotification);
        const bool limited =
            encodings[0].format == "MP3" || (secondaryEnabled && encodings[1].format == "MP3");
        if (limited && encodings[0].rate > 48000)
            encodings[0].rate = encodings[1].rate = 48000;
        for (int value : {88200, 96000, 192000})
            rate.setItemEnabled(value, !limited);
        rate.setSelectedId((int)encodings[0].rate, dontSendNotification);
        channels.setSelectedId(encodings[0].channels, dontSendNotification);
        format.setEnabled(selectedOutput == 0 || secondaryEnabled);
        quality.setEnabled(format.isEnabled());
        updating = false;
        repaint();
    }
    void rebuild() {
        if (rendering && session.busy)
            return;
        jobs.clear();
        if (const auto *song = session.song()) {
            jobs = audioExport::plan(session.project(), *song, source.getSelectedId() - 1,
                                     bounds.getSelectedId() - 1, pattern.getText(), tracks, clips,
                                     regions, area, encodings[0]);
            if (secondaryEnabled)
                audioExport::appendSecondary(
                    jobs, audioExport::plan(session.project(), *song, source.getSelectedId() - 1,
                                            bounds.getSelectedId() - 1, pattern.getText(), tracks,
                                            clips, regions, area, encodings[1]));
        }
        files.updateContent();
        files.repaint();
        renderButton.setEnabled(!jobs.empty());
        repaint();
    }
    int getNumRows() override { return (int)jobs.size(); }
    void paintListBoxItem(int row, Graphics &g, int width, int height, bool selected) override {
        if (row < 0 || row >= (int)jobs.size())
            return;
        const auto &job = jobs[(size_t)row];
        if (selected) {
            g.setColour(theme::green.withAlpha(.15f));
            g.fillAll();
        }
        g.setColour(Colours::white);
        g.setFont(theme::font(12));
        g.drawFittedText(job.name, 8, 0, width - 120, height, Justification::centredLeft, 1);
        g.setColour(theme::secondary);
        g.drawText(String(job.end - job.start, 2) + " s", width - 105, 0, 95, height,
                   Justification::centredRight);
    }
    void chooseDirectory() {
        chooser = std::make_unique<FileChooser>(String::fromUTF8("Diretório de saída"),
                                                File(directory.getText()), "", true);
        chooser->launchAsync(FileBrowserComponent::openMode |
                                 FileBrowserComponent::canSelectDirectories,
                             [safe = SafePointer<ExportPanel>(this)](const FileChooser &fc) {
                                 if (safe && fc.getResult() != File())
                                     safe->directory.setText(fc.getResult().getFullPathName());
                             });
    }
    void start() {
        try {
            if (!File::isAbsolutePath(directory.getText()))
                throw std::runtime_error("Escolha um diretório de saída válido.");
            ExportRequest request;
            request.directory = File(directory.getText());
            request.jobs = jobs;
            request.encodings[0] = encodings[0];
            request.encodings[1] = encodings[1];
            session.exportAudio(std::move(request));
            rendering = session.busy;
            status.clear();
            for (auto *c : std::initializer_list<Component *>{
                     &source, &bounds, &format, &quality, &rate, &channels, &directory, &pattern,
                     &browse, &primary, &secondary, &enableSecondary})
                c->setEnabled(!rendering);
            for (auto *button : tokens)
                button->setEnabled(!rendering);
            renderButton.setButtonText(rendering ? "Cancelar" : "Renderizar");
        } catch (const std::exception &e) {
            status = String::fromUTF8(e.what());
            if (error)
                error(status);
        }
        repaint();
    }
    void timerCallback() override {
        if (rendering && !session.busy) {
            rendering = false;
            status = session.message;
            for (auto *c : getChildren())
                c->setEnabled(true);
            updateEncoding();
            renderButton.setButtonText("Renderizar");
        }
        if (rendering)
            repaint();
    }
};
} // namespace catlive
