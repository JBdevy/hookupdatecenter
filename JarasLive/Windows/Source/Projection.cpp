#include "Projection.h"
namespace catlive {
Projection::Projection(Session &value, String target, StageState *state)
    : session(value), role(std::move(target)), stage(state),
      profile(role == "teleprompt2" ? 2 : 1) {
    addAndMakeVisible(video);
    addAndMakeVisible(textView);
    addAndMakeVisible(status);

    addAndMakeVisible(fontUp);
    addAndMakeVisible(fontDown);
    textView.setReadOnly(true);
    textView.setMultiLine(true);
    textView.setScrollbarsShown(true);
    textView.setFont(theme::font(textSize, true));
    textView.setColour(TextEditor::backgroundColourId, Colours::black);
    textView.setColour(TextEditor::outlineColourId, Colours::transparentBlack);
    setWantsKeyboardFocus(true);
    video.addMouseListener(this, true);
    textView.addMouseListener(this, true);
    fontUp.setVisible(role != "video" && !stage);
    fontDown.setVisible(role != "video" && !stage);
    status.setVisible(!stage && role != "video");
    textView.setVisible(!stage);
    import.onClick = [this] { chooseMedia(); };
    fontUp.onClick = [this] {
        textSize = jlimit(14.f, 120.f, textSize + 4);
        textView.setFont(theme::font(textSize, true));
    };
    fontDown.onClick = [this] {
        textSize = jlimit(14.f, 120.f, textSize - 4);
        textView.setFont(theme::font(textSize, true));
    };
    video.setAudioVolume(0);
    startTimerHz(20);
}
Projection::~Projection() {
    stopTimer();
    video.stop();
    video.closeVideo();
}
void Projection::resized() {
    auto content = mediaBounds();
    video.setBounds(content);
    textView.setBounds(content.reduced(22));
    status.setBounds(12, 3, getWidth() - 180, 25);
    import.setBounds(getWidth() - 86, 3, 74, 26);
    fontUp.setBounds(getWidth() - 110, 3, 45, 26);
    fontDown.setBounds(getWidth() - 58, 3, 45, 26);
}
void Projection::paint(Graphics &g) {
    g.fillAll(Colours::black);
    if (image.isValid()) {
        const auto bounds = mediaBounds();
        const bool stretch = stage && flag(stage->settings(profile), "mediaStretch");
        g.drawImageWithin(image, bounds.getX(), bounds.getY(), bounds.getWidth(),
                          bounds.getHeight(),
                          stretch ? RectanglePlacement::stretchToFit : RectanglePlacement::centred);
    }
}
juce::Rectangle<int> Projection::mediaBounds() const {
    if (role == "video") return getLocalBounds();
    if (!stage)
        return getLocalBounds().withTrimmedTop(34);
    return getLocalBounds().reduced(8).withTrimmedTop(
        flag(stage->settings(profile), "hideTransport") ? 0 : 108);
}
void Projection::paintOverChildren(Graphics &g) {
    if (stage)
        paintStage(g);
}
void Projection::toggleFullScreen() {
    if (auto *window = findParentComponentOfClass<DocumentWindow>()) {
        if (presenting) {
            presenting = false;
            window->setAlwaysOnTop(windowedOnTop);
            window->setResizable(true, false);
            window->setDropShadowEnabled(true);
            window->setTitleBarHeight(windowedTitleHeight);
            window->setTitleBarButtonsRequired(DocumentWindow::allButtons, false);
            window->setBounds(windowedBounds);
            if (windowedMaximised) window->setFullScreen(true);
        } else {
            const auto *display = Desktop::getInstance().getDisplays().getDisplayForRect(window->getBounds());
            if (!display) return;
            const auto screen = display->totalArea;
            windowedBounds = window->getBounds();
            windowedTitleHeight = window->getTitleBarHeight();
            windowedOnTop = window->isAlwaysOnTop();
            windowedMaximised = window->isFullScreen();
            if (windowedMaximised) window->setFullScreen(false);
            presenting = true;
            window->setResizable(false, false);
            window->setDropShadowEnabled(false);
            window->setTitleBarButtonsRequired(0, false);
            window->setTitleBarHeight(0);
            window->setAlwaysOnTop(true);
            window->setBounds(screen);
        }
        window->toFront(true);
        grabKeyboardFocus();
    }
}
bool Projection::keyPressed(const KeyPress &key) {
    if (key == KeyPress::escapeKey && presenting) {
        toggleFullScreen(); return true;
    }
    return false;
}
void Projection::mouseDown(const MouseEvent &e) {
    grabKeyboardFocus();
    if (!e.mods.isPopupMenu()) return;
    PopupMenu menu;
    if (stage) menu.addItem(1, String::fromUTF8("Configurações"));
    else if (role == "video") {
        PopupMenu settings;
        settings.addItem(4, String::fromUTF8("Importar vídeo ou imagem…"));
        menu.addSubMenu(String::fromUTF8("Configurações"), settings);
    }
    menu.addItem(2, presenting ? "Sair da tela cheia" : "Tela cheia");
    if (stage) menu.addItem(3, "Retirar recado", stage->noticeActive());
    menu.showMenuAsync(PopupMenu::Options().withTargetComponent(this),
        [safe = SafePointer<Projection>(this)](int id) {
            if (!safe) return;
            if (id == 1 && safe->configure) safe->configure();
            if (id == 2) safe->toggleFullScreen();
            if (id == 3 && safe->stage) safe->stage->clearNotice();
            if (id == 4) safe->chooseMedia();
        });
}
void Projection::mouseDoubleClick(const MouseEvent &e) {
    if (!e.mods.isPopupMenu()) toggleFullScreen();
}
void Projection::timerCallback() {
    if (stage) {
        resized();
        repaint();
    }
    const jaras::AudioClip *clip = nullptr;
    auto at = session.transport().position;
    if (auto *song = session.song())
        for (auto &track : song->tracks)
            if (text(track.role.id) == role && !track.mute)
                for (auto &item : track.clips)
                    if (at >= item.startTime && at < item.startTime + item.duration && !item.muted)
                        clip = &item;
    if (!clip) {
        video.stop();
        video.setVisible(false);
        textView.setVisible(false);
        if (image.isValid()) {
            image = {};
            repaint();
        }
        clipID.clear();
        lyrics.clear();
        status.setText(role == "video" ? "Video"
                                       : String::fromUTF8("Teleprompter · nenhum item neste ponto"),
                       dontSendNotification);
        return;
    }
    if (clip->id != clipID || (clip->text && text(*clip->text) != lyrics)) {
        clipID = clip->id;
        itemStart = clip->startTime;
        itemDuration = clip->duration;
        loaded = false;
        image = {};
        video.stop();
        video.closeVideo();
        if (clip->text) {
            lyrics = text(*clip->text);
            textView.setText(lyrics, false);
            textView.moveCaretToTop(false);
            textView.setVisible(!stage);
            video.setVisible(false);
        } else if (clip->audioFile) {
            lyrics.clear();
            textView.setVisible(false);
            try {
                auto file =
                    ProjectCodec::resolveMedia(session.mediaDirectory, clip->audioFile->path);
                if (file.hasFileExtension("png;jpg;jpeg;bmp;gif")) {
                    image = ImageFileFormat::loadFrom(file);
                    video.setVisible(false);
                    if (!image.isValid())
                        throw std::runtime_error("Unable to decode image.");
                } else {
                    auto result = video.load(file);
                    if (result.failed())
                        throw std::runtime_error(utf8(result.getErrorMessage()));
                    video.setAudioVolume(0);
                    video.setVisible(true);
                    loaded = true;
                }
            } catch (const std::exception &e) {
                status.setText(String::fromUTF8(e.what()), dontSendNotification);
            }
        }
        repaint();
    }
    itemStart = clip->startTime;
    itemDuration = clip->duration;
    if (loaded) {
        double source = clip->sourceOffset + (at - clip->startTime) * clip->playbackRate;
        if (std::abs(video.getPlayPosition() - source) > .1 ||
            (!session.transport().playing && std::abs(video.getPlayPosition() - source) > .01))
            video.setPlayPosition(source);
        video.setPlaySpeed(clip->playbackRate);
        if (session.transport().playing && !video.isPlaying())
            video.play();
        if (!session.transport().playing && video.isPlaying())
            video.stop();
    }
    status.setText(text(clip->name) + "  " + clockText(at, true), dontSendNotification);
}
void Projection::chooseMedia() {
    chooser = std::make_unique<FileChooser>(
        "Video / image", File::getSpecialLocation(File::userDocumentsDirectory),
        "*.mp4;*.mov;*.avi;*.mkv;*.wmv;*.png;*.jpg;*.jpeg", true);
    chooser->launchAsync(FileBrowserComponent::openMode | FileBrowserComponent::canSelectFiles,
                         [safe = Component::SafePointer<Projection>(this)](const FileChooser &fc) {
                             if (!safe || fc.getResult() == File())
                                 return;
                             try {
                                 auto file = fc.getResult();
                                 double duration = 30;
                                 if (!file.hasFileExtension("png;jpg;jpeg;bmp;gif")) {
                                     auto result = safe->video.load(file);
                                     if (result.failed())
                                         throw std::runtime_error(utf8(result.getErrorMessage()));
                                     duration = safe->video.getVideoDuration();
                                     safe->video.closeVideo();
                                 }
                                 safe->session.importVideo(file, duration);
                             } catch (const std::exception &e) {
                                 if (safe->error)
                                     safe->error(String::fromUTF8(e.what()));
                             }
                         });
}
} // namespace catlive
#include "ProjectionStage.h"
