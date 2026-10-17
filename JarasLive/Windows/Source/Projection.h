#pragma once
#include "Session.h"
#include "StageState.h"
#include "VideoFadeSurface.h"
#include <condition_variable>
#include <thread>
namespace catlive {
class Projection final : public Component, private Timer {
  public:
    Projection(Session &, String role = "video", StageState *stage = nullptr);
    ~Projection() override;
    void resized() override;
    void paint(Graphics &) override;
    void paintOverChildren(Graphics &) override;
    void mouseDown(const MouseEvent &) override;
    void mouseDoubleClick(const MouseEvent &) override;
    bool keyPressed(const KeyPress &) override;
    std::function<void(String)> error;
    std::function<void()> configure;

  private:
    Session &session;
    String role;
    VideoComponent video{false};
    VideoFadeSurface videoFade;
    TextEditor textView;
    Image image;
    Image stillFrame;
    struct StillRequest { File file; double source; uint64 serial; };
    std::mutex stillMutex;
    std::condition_variable stillSignal;
    std::optional<StillRequest> pendingStill;
    std::thread stillWorker;
    bool stopStillWorker = false;
    uint64 stillSerial = 0;
    File stillFile;
    double requestedStillTime = -1;
    void requestStillFrame(const File &, double);
    float mediaOpacity = 1;
    StageState *stage = nullptr;
    String lyrics;
    int profile = 1;
    double itemStart = 0, itemDuration = 0;
    void paintStage(Graphics &);
    juce::Rectangle<int> mediaBounds() const;
    Label status;
    TextButton fontUp{"A+"}, fontDown{"A-"};
    ID clipID;
    float textSize = 36;
    bool loaded = false;
    void timerCallback() override;
    void toggleFullScreen();
    juce::Rectangle<int> windowedBounds;
    int windowedTitleHeight = 32;
    bool presenting = false, windowedOnTop = false, windowedMaximised = false;
};
} // namespace catlive
