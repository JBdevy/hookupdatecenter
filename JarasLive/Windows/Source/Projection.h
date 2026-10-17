#pragma once
#include "Session.h"
#include "StageState.h"
#include "Appearance.h"
#include "native_video_decoder.h"
namespace catlive {
class Projection final : public Component, private Timer {
  public:
    Projection(Session &, Appearance &, String role = "video", StageState *stage = nullptr);
    ~Projection() override;
    void resized() override;
    void paint(Graphics &) override;
    void paintOverChildren(Graphics &) override;
    void mouseDown(const MouseEvent &) override;
    void mouseDoubleClick(const MouseEvent &) override;
    bool keyPressed(const KeyPress &) override;
    void refreshVideoAppearance();
    std::function<void(String)> error;
    std::function<void()> configure;

  private:
    Session &session;
    Appearance &appearance;
    String role;
    vshook_video::Decoder videoDecoder;
    TextEditor textView;
    Image image;
    vshook_video::DecodedFrame videoFrame;
    std::vector<std::uint8_t> grayscalePixels;
    uint64 grayscaleSequence = 0;
    HWND videoSurface = nullptr;
    File videoFile;
    uint64 videoSequence = 0;
    void updateVideoFrame(double source, bool playing, double rate);
    void updateVideoSurface();
    void paintVideoSurface(HDC);
    static LRESULT CALLBACK videoSurfaceProc(HWND, UINT, WPARAM, LPARAM);
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
