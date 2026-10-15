#pragma once
#include "Session.h"
#include "StageState.h"
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
    std::function<void(String)> error;
    std::function<void()> configure;

  private:
    Session &session;
    String role;
    VideoComponent video{false};
    TextEditor textView;
    Image image;
    StageState *stage = nullptr;
    String lyrics;
    int profile = 1;
    double itemStart = 0, itemDuration = 0;
    void paintStage(Graphics &);
    juce::Rectangle<int> mediaBounds() const;
    Label status;
    TextButton import{"Import"}, fontUp{"A+"}, fontDown{"A-"};
    std::unique_ptr<FileChooser> chooser;
    ID clipID;
    float textSize = 36;
    bool loaded = false;
    void timerCallback() override;
    void chooseMedia();
};
} // namespace catlive
