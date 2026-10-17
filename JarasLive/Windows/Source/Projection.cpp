#include "ProjectionSelection.h"
#include "MediaSource.h"
#include "Projection.h"
#include "../../Core/Tracks/ItemFade.hpp"
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
    fontUp.onClick = [this] {
        textSize = jlimit(14.f, 120.f, textSize + 4);
        textView.setFont(theme::font(textSize, true));
    };
    fontDown.onClick = [this] {
        textSize = jlimit(14.f, 120.f, textSize - 4);
        textView.setFont(theme::font(textSize, true));
    };
    video.setAudioVolume(0);
    Component::SafePointer<Projection> safe(this);
    stillWorker=std::thread([this,safe] {
        for(;;) {
            StillRequest request;
            {
                std::unique_lock<std::mutex> lock(stillMutex);
                stillSignal.wait(lock,[this]{return stopStillWorker||pendingStill.has_value();});
                if(stopStillWorker)return;
                request=*pendingStill;pendingStill.reset();
            }
            Image frame;
            try {frame=decodeVideoFrame(request.file,request.source);}catch(...){}
            MessageManager::callAsync([safe,
                                       serial=request.serial,file=request.file,frame=std::move(frame)]() mutable {
                if(!safe||serial!=safe->stillSerial||file!=safe->stillFile||!frame.isValid())return;
                safe->stillFrame=std::move(frame);
                if(!safe->session.transport().playing)safe->video.setVisible(false);
                safe->repaint();
            });
        }
    });
    startTimerHz(role == "video" ? 60 : 20);
}
Projection::~Projection() {
    stopTimer();
    {std::lock_guard<std::mutex> lock(stillMutex);stopStillWorker=true;pendingStill.reset();}
    stillSignal.notify_one();if(stillWorker.joinable())stillWorker.join();
    video.stop();
    video.closeVideo();
}
void Projection::resized() {
    auto content = mediaBounds();
    video.setBounds(content);
    textView.setBounds(content.reduced(22));
    status.setBounds(12, 3, getWidth() - 180, 25);
    fontUp.setBounds(getWidth() - 110, 3, 45, 26);
    fontDown.setBounds(getWidth() - 58, 3, 45, 26);
}
void Projection::paint(Graphics &g) {
    g.fillAll(Colours::black);
    if (image.isValid()) {
        g.setOpacity(mediaOpacity);
        const auto bounds = mediaBounds();
        const bool stretch = stage && flag(stage->settings(profile), "mediaStretch");
        g.drawImageWithin(image, bounds.getX(), bounds.getY(), bounds.getWidth(),
                          bounds.getHeight(),
                          stretch ? RectanglePlacement::stretchToFit : RectanglePlacement::centred);
    }
    if(stillFrame.isValid()&&!session.transport().playing) {
        g.setOpacity(mediaOpacity);
        const auto bounds=mediaBounds();
        g.drawImageWithin(stillFrame,bounds.getX(),bounds.getY(),bounds.getWidth(),bounds.getHeight(),RectanglePlacement::centred);
    }
}
void Projection::requestStillFrame(const File &file,double source) {
    if(file==stillFile&&std::abs(requestedStillTime-source)<.015)return;
    if(file!=stillFile){stillFrame={};stillFile=file;}
    requestedStillTime=source;
    {std::lock_guard<std::mutex> lock(stillMutex);pendingStill=StillRequest{file,source,++stillSerial};}
    stillSignal.notify_one();
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
    // Projection windows have no context menu on macOS. Their controls live
    // on the Video/TP buttons in the workspace.
}
void Projection::mouseDoubleClick(const MouseEvent &e) {
    if (!e.mods.isPopupMenu()) toggleFullScreen();
    else if(role=="video")if(auto *window=findParentComponentOfClass<DocumentWindow>())window->closeButtonPressed();
}
void Projection::timerCallback() {
    if (stage) {
        resized();
        repaint();
    }
    const jaras::AudioClip *clip = nullptr;
    auto at = session.transport().playing || session.transport().paused ? session.transport().position : session.transport().editPosition;
    if (auto *song = session.song()) clip = firstProjectionItem(*song,at,role);
    if (!clip) {
        videoFade.hide();
        stillFrame={};stillFile={};requestedStillTime=-1;++stillSerial;
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
    const auto opacity = (float)jaras::itemFadeGain(*clip, at);
    if (opacity != mediaOpacity) { mediaOpacity = opacity; repaint(); }
    if (clip->id != clipID || (clip->text && text(*clip->text) != lyrics)) {
        clipID = clip->id;
        itemStart = clip->startTime;
        itemDuration = clip->duration;
        loaded = false;
        stillFrame={};stillFile={};requestedStillTime=-1;++stillSerial;
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
        if(session.transport().playing) {
            if(!video.isVisible())video.setVisible(true);
            if(std::abs(video.getPlayPosition()-source)>.1)video.setPlayPosition(source);
            video.setPlaySpeed(clip->playbackRate);
            if(!video.isPlaying())video.play();
        } else {
            if(video.isPlaying())video.stop();
            requestStillFrame(ProjectCodec::resolveMedia(session.mediaDirectory,clip->audioFile->path),source);
            if(stillFrame.isValid())video.setVisible(false);
        }
    }
    status.setText(text(clip->name) + "  " + clockText(at, true), dontSendNotification);
    videoFade.update(video,mediaOpacity);
}

} // namespace catlive
#include "ProjectionStage.h"
