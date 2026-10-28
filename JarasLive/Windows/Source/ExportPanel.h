#pragma once
#include "Localization.h"
#include "Session.h"
#include "ModalSheet.h"
#include "ConfirmationStyle.h"
#include "Appearance.h"
namespace catlive {
class ItemExportProcessingPanel final : public Component {
    TextButton pre{"Pre-Processing"},post{"Post-Processing"},cancel{localization::translate("Cancel")};
  public:
    explicit ItemExportProcessingPanel(std::function<void(bool)> choose) {
        setComponentID("itemExportProcessing");
        getProperties().set("selfContainedSheet",true);
        getProperties().set("sheetCornerRadius",(double)confirmationStyle::radius);
        for(auto *button:{&pre,&post,&cancel}) {
            addAndMakeVisible(button);button->getProperties().set("fontSize",confirmationStyle::buttonSize);
            button->getProperties().set("cornerRadius",confirmationStyle::buttonHeight/2.f);
            button->getProperties().set("flat",true);
        }
        pre.setComponentID("itemExportPreProcessing");post.setComponentID("itemExportPostProcessing");
        auto select=[this,choose](bool raw) {
            ModalSheet::dismiss(*this);
            MessageManager::callAsync([choose,raw]{choose(raw);});
        };
        pre.onClick=[select]{select(true);};post.onClick=[select]{select(false);};
        cancel.onClick=[this]{ModalSheet::dismiss(*this);};
    }
    void paint(Graphics &g) override {
        confirmationStyle::surface(g,getLocalBounds().toFloat());g.setColour(Colours::white);
        g.setFont(theme::semiboldFont(confirmationStyle::titleSize));
        g.drawText(localization::translate("Export audio items"),20,18,getWidth()-40,24,Justification::centredLeft);
    }
    void resized() override {
        int y=52;
        for(auto *button:{&pre,&post,&cancel}) {
            button->setBounds(20,y,getWidth()-40,confirmationStyle::buttonHeight);
            y+=confirmationStyle::buttonHeight+confirmationStyle::gap;
        }
    }
};
class ExportReplacementPanel final : public Component {
    TextButton cancel{localization::translate("Cancel")}, replace{localization::translate("Replace")};
    String names;
public:
    ExportReplacementPanel(const std::set<String> &files, std::function<void()> accepted) {
        getProperties().set("selfContainedSheet",true);
        getProperties().set("sheetCornerRadius",double(confirmationStyle::radius));
        setComponentID("exportReplacementConfirmation");
        for (const auto &file : files) { if (names.isNotEmpty()) names += "\n"; names += file; }
        for (auto *button : {&cancel,&replace}) {
            addAndMakeVisible(button); button->getProperties().set("flat",true);
            button->getProperties().set("cornerRadius",15.0);
        }
        replace.setColour(TextButton::buttonColourId,theme::green);
        replace.setColour(TextButton::textColourOffId,Colours::black);
        cancel.onClick=[this]{ModalSheet::dismiss(*this);};
        replace.onClick=[this,accepted]{ModalSheet::dismiss(*this);MessageManager::callAsync(accepted);};
    }
    void paint(Graphics &g) override {
        confirmationStyle::surface(g,getLocalBounds().toFloat());g.setColour(Colours::white);
        g.setFont(theme::semiboldFont(14));
        g.drawFittedText(localization::translate("Replace existing files?"),20,16,getWidth()-40,36,Justification::centredLeft,2,1.f);
        g.setFont(theme::font(12));
        g.drawFittedText(names,20,58,getWidth()-40,getHeight()-120,Justification::topLeft,6,1.f);
    }
    void resized() override {
        const int width=(getWidth()-48)/2;
        cancel.setBounds(20,getHeight()-50,width,30);replace.setBounds(28+width,getHeight()-50,width,30);
    }
};
class ExportPanel final : public Component, private ListBoxModel, private Timer {
  public:
    ExportPanel(Session &owner, ID track, ID clip, std::function<void(String)> failure, bool stems = false, bool preProcessingItems = false, File preferenceFile = {})
        : session(owner), error(std::move(failure)), preProcessing(preProcessingItems), preferences(preferenceFile) {
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
        directory.setText(preferences.value("jaras.export.directory", (session.document == File()
                               ? File::getSpecialLocation(File::userDesktopDirectory)
                               : session.document.getParentDirectory())
                              .getFullPathName()).toString());
        directory.onFocusLost = [this] { rememberDirectory(); };
        directory.onReturnKey = [this] { rememberDirectory(); };
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
        channels.addItem(localization::translate(String::fromUTF8("Estéreo")), 2);
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
            if (renderScreen) { ModalSheet::dismiss(*this); return; }
            start();
        };
        restorePreferences(stems);
        updateEncoding();
        rebuild();
        startTimerHz(20);
    }
    void selectRegions(std::set<ID> ids) {
        regions = std::move(ids); tracks.clear(); clips.clear();
        regionMode = true;
        bounds.setSelectedId(3, dontSendNotification);
        pattern.setText(str(preferences.value("catlive.export.options"), "regionFileName", "%region"), false); rebuild();
    }
    ~ExportPanel() override {
        stopTimer();
        rememberPreferences();
        files.setModel(nullptr);
    }
    var diagnostics() const {
        auto value=object();put(value,"jobs",(int)jobs.size());put(value,"source",source.getSelectedId());
        put(value,"bounds",bounds.getSelectedId());put(value,"secondary",secondaryEnabled);
        put(value,"primaryFormat",encodings[0].format);put(value,"secondaryFormat",encodings[1].format);
        put(value,"primaryBits",encodings[0].bits);put(value,"secondaryBits",encodings[1].bits);
        put(value,"primaryBitrate",encodings[0].bitrate);put(value,"secondaryBitrate",encodings[1].bitrate);
        put(value,"sampleRate",encodings[0].rate);put(value,"channels",encodings[0].channels);
        put(value,"outputTab",selectedOutput);put(value,"fileName",pattern.getText());put(value,"directory",directory.getText());
        return value;
    }
    void paint(Graphics &g) override {
        g.fillAll(theme::panel);
        if (renderScreen) { paintRender(g); return; }
        g.setColour(Colours::white);
        g.setFont(theme::font(13));
        auto label = [&](String text, int x, int y, int width) {
            g.drawText(text, x, y, width, 26, Justification::centredLeft);
        };
        label(localization::translate("Origem"), 20, 12, 52);
        label(localization::translate("Limites"), 232, 12, 52);
        g.setColour(theme::secondary);
        g.setFont(theme::font(10));
        g.drawText(String((int)jobs.size()) + " arquivos", getWidth() - 130, 12, 110, 26,
                   Justification::centredRight);
        g.setColour(Colour(0xff2b2b2b));
        g.fillRoundedRectangle(20, 66, getWidth() - 40.f, 92, 10);
        g.setColour(Colours::white);
        g.setFont(theme::font(13));
        label(String::fromUTF8("Diretório:"), 34, 80, 130);
        label(localization::translate("Nome do arquivo:"), 34, 116, 130);
        g.setColour(Colour(0xff151515));
        g.fillRoundedRectangle(20, getHeight() - 128.f, 420, 78, 5);
        g.setColour(Colours::white);
        g.setFont(theme::font(12));
        const int formatY = getHeight() - 81;
        label(localization::translate("Formato"), 30, formatY, 58);
        label(encodings[selectedOutput].format == "MP3" ? "Taxa de bits" : "Bits", 174, formatY,
              78);
        g.setFont(theme::font(10));
        label(localization::translate("Taxa de amostragem"), 20, getHeight() - 36, 110);
        label(localization::translate("Canais"), 240, getHeight() - 36, 48);
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
        if (renderScreen) { renderButton.setBounds(getWidth() - 110, getHeight() - 52, 90, 30); return; }
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
    bool preProcessing = false, regionMode = false;
    Appearance preferences;
    std::set<ID> tracks, clips, regions;
    std::optional<std::pair<double, double>> area;
    ComboBox source, bounds, format, quality, rate, channels;
    TextEditor directory, pattern;
    TextButton browse, primary{localization::translate(String::fromUTF8("Formato de saída principal"))},
        secondary{String::fromUTF8("Formato de saída secundária")}, renderButton{"Renderizar"};
    ToggleButton enableSecondary{localization::translate(String::fromUTF8("Ativar saída secundária"))};
    OwnedArray<TextButton> tokens;
    ListBox files;
    std::vector<ExportJob> jobs;
    ExportEncoding encodings[2];
    int selectedOutput = 0;
    bool updating = false, secondaryEnabled = false, rendering = false;
    String status;
    bool renderScreen = false;
    void paintRender(Graphics &g) {
        const auto progress = session.exportProgress();
        const int left = 24, width = getWidth() - 48;
        g.setColour(Colours::white); g.setFont(theme::semiboldFont(18));
        g.drawText(localization::translate("Rendering"), left, 20, width, 28, Justification::centredLeft);
        g.setFont(theme::semiboldFont(12));
        g.drawText(progress.fileName, left, 70, width, 26, Justification::centredLeft);
        const juce::Rectangle<float> wave(float(left), 112.f, float(width), 180.f);
        g.setColour(Colour(0xff101010)); g.fillRoundedRectangle(wave, 6);
        const float binWidth = wave.getWidth() / progress.waveform.size();
        const int last = std::min(600, int(std::ceil(progress.fraction * 600)));
        for (int index = 0; index < last; ++index) {
            const auto peak = progress.waveform[size_t(index)];
            const float amplitude = std::min(1.f, peak) * (wave.getHeight() / 2 - 3);
            g.setColour(peak >= 1 ? Colours::red : theme::green);
            g.fillRect(wave.getX() + index * binWidth, wave.getCentreY() - amplitude, std::max(1.f, binWidth), std::max(1.f, 2 * amplitude));
        }
        g.setColour(Colour(0xff3b3b3b)); g.fillRoundedRectangle(float(left), 310.f, float(width), 5.f, 2.5f);
        g.setColour(theme::green); g.fillRoundedRectangle(float(left), 310.f, float(width * progress.fraction), 5.f, 2.5f);
        g.setColour(theme::secondary); g.setFont(theme::font(12));
        g.drawText(String(progress.completed) + " / " + String(progress.total) + " " + localization::translate("files"), left, 326, width / 2, 24, Justification::centredLeft);
        g.setColour(progress.peak >= 1 ? Colours::red : theme::secondary);
        g.drawText(progress.peak > 0 ? "Peak " + String(20 * std::log10(progress.peak), 2) + " dBFS" : String::fromUTF8("Peak −∞ dBFS"), left + width / 2, 326, width / 2, 24, Justification::centredRight);
        if (!session.busy) {
            g.setColour(session.exportFailed ? Colours::red : theme::green);
            g.drawFittedText(status, left, 370, width, std::max(30, getHeight() - 440), Justification::centredLeft, 3);
        }
    }
    std::unique_ptr<FileChooser> chooser;
    void rememberDirectory() {
        const auto path = directory.getText().trim();
        if (File::isAbsolutePath(path)) preferences.set("jaras.export.directory", path);
    }
    void restorePreferences(bool stems) {
        const auto saved = preferences.value("catlive.export.options");
        source.setSelectedId(stems ? 4 : jlimit(1,4,(int)get(saved,"source",1)),dontSendNotification);
        bounds.setSelectedId(jlimit(1,4,(int)get(saved,"bounds",1)),dontSendNotification);
        pattern.setText(str(saved,"fileName","%project"),false);
        selectedOutput=jlimit(0,1,(int)get(saved,"outputTab",0));
        secondaryEnabled=flag(saved,"secondary",false);
        for(int i=0;i<2;++i) {
            auto &encoding=encodings[i];const String prefix=i==0 ? "primary" : "secondary";
            auto value=str(saved,Identifier(prefix+"Format"),i==0 ? "WAV" : "MP3");
            encoding.format=StringArray{"WAV","AIFF","MP3"}.contains(value) ? value : "WAV";
            const int bits=(int)get(saved,Identifier(prefix+"Bits"),24);
            encoding.bits=bits==16||bits==24||bits==32 ? bits : 24;
            const int bitrate=(int)get(saved,Identifier(prefix+"Bitrate"),320);
            encoding.bitrate=std::set<int>{64,96,128,160,192,224,256,320}.count(bitrate) ? bitrate : 320;
            encoding.channels=(int)get(saved,"channels",2)==1 ? 1 : 2;
            encoding.rate=(double)get(saved,"sampleRate",48000)==44100 ? 44100 : 48000;
        }
    }
    void rememberPreferences() {
        auto saved=diagnostics();
        if(regionMode) {
            const auto previous=preferences.value("catlive.export.options");
            put(saved,"regionFileName",pattern.getText());
            put(saved,"fileName",get(previous,"fileName","%project"));
            put(saved,"source",get(previous,"source",1));put(saved,"bounds",get(previous,"bounds",1));
        } else put(saved,"regionFileName",get(preferences.value("catlive.export.options"),"regionFileName","%region"));
        preferences.set("catlive.export.options",saved);
        rememberDirectory();
    }
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
                                 if (safe && fc.getResult() != File()) {
                                     safe->directory.setText(fc.getResult().getFullPathName());
                                     safe->rememberDirectory();
                                 }
                             });
    }
    void start(std::optional<ExportRequest> approved = {}) {
        try {
            if (!File::isAbsolutePath(directory.getText()))
                throw std::runtime_error("Escolha um diretório de saída válido.");
            rememberPreferences();
            ExportRequest request;
            request.directory = File(directory.getText());
            request.jobs = jobs;
            request.preProcessingItems = preProcessing;
            request.encodings[0] = encodings[0];
            request.encodings[1] = encodings[1];
            if (approved) request = std::move(*approved);
            else {
                for (const auto &job : request.jobs)
                    if (request.directory.getChildFile(job.name).exists()) request.replaceExistingFiles.insert(job.name);
                if (!request.replaceExistingFiles.empty()) {
                    const auto files = request.replaceExistingFiles;
                    auto accept = [safe=SafePointer<ExportPanel>(this),request=std::move(request)]() mutable {
                        if (safe) safe->start(std::move(request));
                    };
                    ModalSheet::open(*this,localization::translate("Replace existing files?"),
                        std::make_unique<ExportReplacementPanel>(files,std::move(accept)),360,250);
                    return;
                }
            }
            session.exportAudio(std::move(request));
            rendering = session.busy;
            renderScreen = rendering;
            if (renderScreen) {
                for (auto *child : getChildren()) child->setVisible(child == &renderButton);
                resized();
            }
            status.clear();
            for (auto *c : std::initializer_list<Component *>{
                     &source, &bounds, &format, &quality, &rate, &channels, &directory, &pattern,
                     &browse, &primary, &secondary, &enableSecondary})
                c->setEnabled(!rendering);
            for (auto *button : tokens)
                button->setEnabled(!rendering);
            renderButton.setButtonText(rendering ? localization::translate("Cancelar") : localization::translate("Renderizar"));
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
            renderButton.setEnabled(true);
            renderButton.setButtonText(localization::translate("Close"));
            repaint();
        }
        if (rendering)
            repaint();
    }
};
} // namespace catlive
