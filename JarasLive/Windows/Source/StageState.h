#pragma once
#include "ConfirmationPanel.h"
#include "Appearance.h"
#include "Localization.h"
namespace catlive {
class StageState final {
  public:
    explicit StageState(Appearance &p) : preferences(p) {
        const auto saved = p.value("jaras.teleprompter.timer");
        target = jlimit(0, 359999, (int)num(saved, "targetSeconds"));
        autoStart = flag(saved, "initAutoEnabled");
    }
    Appearance &preferences;
    int target = 0, previewPage = 0;
    bool running = false, autoStart = false, preview = false;
    double started = 0;
    String notice;
    Image noticeImage;
    bool pinned = false, pinWhenStopped = false, stoppedNoticeActive = false;
    bool noticePlaybackRunning = false;
    String stoppedNotice;
    Image stoppedImage;
    void setPinWhenStopped(bool enabled, String message = {}, Image image = {}) {
        pinWhenStopped = enabled;
        if (enabled) {
            stoppedNotice = message.trim().substring(0,500); stoppedImage = image;
            if (!noticePlaybackRunning) presentStoppedNotice();
        } else if (stoppedNoticeActive) clearNotice();
    }
    void presentStoppedNotice() {
        if (stoppedNotice.isEmpty() && !stoppedImage.isValid()) return;
        sendNotice(stoppedNotice, stoppedImage);
        stoppedNoticeActive = true; pinned = true;
    }
    double noticeSent = 0, noticeDeadline = 0, pausedRemaining = 20;
    static double now() { return Time::getMillisecondCounterHiRes() / 1000; }
    double seconds() const { return running ? target - std::max(0., now() - started) : target; }
    String timeText(bool spaced = false) const {
        const int remaining = (int)std::ceil(seconds());
        const auto value = clockText(std::abs(remaining), true);
        return (remaining < 0 ? String::fromUTF8("−") : String()) +
               (spaced ? value.replace(":", " : ") : value);
    }
    void start() {
        if (!running) {
            started = now();
            running = true;
        }
    }
    void reset() { running = false; }
    void saveTimer() {
        auto p = object();
        put(p, "targetSeconds", target);
        put(p, "initAutoEnabled", autoStart);
        preferences.set("jaras.teleprompter.timer", p);
    }
    void observe(const jaras::TransportState &t) {
        const bool playing = t.playing || t.subPlay.playing;
        if (playing != noticePlaybackRunning) {
            noticePlaybackRunning = playing;
            if (playing) { if (stoppedNoticeActive) clearNotice(); }
            else if (pinWhenStopped) presentStoppedNotice();
        }
        if (!t.playing) {
            wasPlaying = false;
            if (!t.paused)
                observed.reset();
            return;
        }
        if (observed != t.regionId || !wasPlaying) {
            if (autoStart && !running)
                start();
            observed = t.regionId;
        }
        wasPlaying = t.playing;
    }
    bool noticeActive() const {
        return (!notice.isEmpty() || noticeImage.isValid()) && (pinned || now() < noticeDeadline);
    }
    String noticeText(const var &settings) const {
        auto value = unicodeCase(notice);
        if (flag(settings, "emojiEnabled")) {
            const auto emoji = str(settings, "emoji", String::fromUTF8("⚠️"));
            value = emoji + " " + value + " " + emoji;
        }
        return value;
    }
    double remaining() const {
        return noticeActive() ? (pinned ? pausedRemaining : std::max(0., noticeDeadline - now()))
                              : 0;
    }
    void sendNotice(String message, Image image = {}) {
        stoppedNoticeActive = false;
        notice = message.trim().substring(0, 500);
        noticeImage = image;
        noticeSent = now();
        pausedRemaining = 20;
        noticeDeadline = now() + 20;
    }
    void clearNotice() {
        stoppedNoticeActive = false;
        notice.clear();
        noticeImage = {};
        pinned = false;
    }
    void togglePin() {
        pausedRemaining = noticeActive() ? remaining() : 20;
        pinned = !pinned;
        if (!pinned)
            noticeDeadline = now() + pausedRemaining;
    }
    String profileKey(int index) const {
        return index == 2 ? "jaras.teleprompter2.settings" : "jaras.teleprompter.settings";
    }
    String preset(int index) const {
        return str(preferences.value(profileKey(index)), "selected", "night");
    }
    var settings(int index) const {
        static const auto defaults = JSON::parse(
            String::fromUTF8(BinaryData::StageDefaults_json, BinaryData::StageDefaults_jsonSize));
        const auto profiles = preferences.value(profileKey(index));
        const auto selected = preset(index);
        auto result = get(defaults, Identifier(selected)).clone();
        if (auto *saved = get(profiles, Identifier(selected)).getDynamicObject())
            for (const auto &entry : saved->getProperties())
                put(result, entry.name, entry.value);
        return result;
    }
    Result set(int index, const String &key, var value) {
        auto profiles = preferences.value(profileKey(index), object()).clone();
        auto current = settings(index);
        put(current, Identifier(key), std::move(value));
        put(profiles, Identifier(preset(index)), current);
        return preferences.set(profileKey(index), profiles);
    }
    void selectPreset(int index, const String &name) {
        auto profiles = preferences.value(profileKey(index), object()).clone();
        put(profiles, "selected", name);
        preferences.set(profileKey(index), profiles);
    }
    static Colour colour(const var &settings, const String &key, uint32 fallback) {
        return Colour(0xff000000u |
                      ((uint32)(int64)get(settings, Identifier(key), (int)fallback) & 0xffffffu));
    }
    static Font font(const var &settings, const String &key, float size) {
        static const std::map<String, String> names{{"arial", "Arial"},
                                                    {"segoe", "Segoe UI"},
                                                    {"bahnschrift", "Bahnschrift"},
                                                    {"verdana", "Verdana"},
                                                    {"tahoma", "Tahoma"},
                                                    {"georgia", "Georgia"},
                                                    {"trebuchet", "Trebuchet MS"},
                                                    {"impact", "Impact"},
                                                    {"mono", "Consolas"}};
        const auto found = names.find(str(settings, Identifier(key), "system"));
        return found == names.end()
                   ? theme::font(size, true)
                   : Font(FontOptions(found->second, size, Font::bold).withPointHeight(size));
    }

  private:
    std::optional<ID> observed;
    bool wasPlaying = false;
};
class StageTimerControl final : public Component, private Timer {
  public:
    StageTimerControl(StageState &s, std::function<void()> configure = {})
        : state(s), settings(std::move(configure)) {
        setComponentID("stageTimerControl");
        for (int i = 0; i < 3; ++i) {
            addAndMakeVisible(digits[i]);
            digits[i].setComponentID(i==0?"timerHours":i==1?"timerMinutes":"timerSeconds");
            digits[i].setTitle(i==0?"HH":i==1?"MM":"SS");
            digits[i].setInputRestrictions(2, "0123456789");
            digits[i].setPopupMenuEnabled(false);
            digits[i].setText("00");
            digits[i].setJustification(Justification::centred);
            digits[i].setFont(theme::semiboldFont(12));
            digits[i].onTextChange = [this] {
                if (!state.running)
                    state.target = jlimit(0, 99, digits[0].getText().getIntValue()) * 3600 +
                                   jlimit(0, 59, digits[1].getText().getIntValue()) * 60 +
                                   jlimit(0, 59, digits[2].getText().getIntValue());
            };
            digits[i].onFocusLost = [this] { state.saveTimer(); };
            digits[i].addMouseListener(this, true);
        }
        addAndMakeVisible(start);start.setComponentID("timerStart");
        start.getProperties().set("flat",true);start.getProperties().set("fontSize",11.f);
        start.context = [this](Point<int>) { if (settings) settings(); };
        start.setColour(TextButton::textColourOffId, theme::green);
        start.onClick = [this] {
            if (state.running) {
                const auto safe = Component::SafePointer<StageTimerControl>(this);
                ConfirmationPanel::show(MessageBoxIconType::QuestionIcon, String::fromUTF8("Cronômetro"),
                                             String::fromUTF8("Parar e reiniciar o cronômetro?"), "Parar", "Cancelar",
                                             this,
                                             ModalCallbackFunction::create([safe](int result) {
                                                 if (safe && result)
                                                     safe->state.reset();
                                             }));
            } else {
                state.target = jlimit(0, 99, digits[0].getText().getIntValue()) * 3600 +
                               jlimit(0, 59, digits[1].getText().getIntValue()) * 60 +
                               jlimit(0, 59, digits[2].getText().getIntValue());
                state.saveTimer();
                state.start();
            }
        };
        startTimerHz(4);
        timerCallback();
    }
    void paint(Graphics &g) override {
        g.setColour(theme::display);
        const auto bounds=getLocalBounds().toFloat().reduced(.5f);
        g.fillRoundedRectangle(bounds, 6);
        g.setColour(theme::line);
        g.drawRoundedRectangle(bounds, 6, 1);
    }
    void resized() override {
        const float scale = std::min(1.f, getWidth() / 157.f);
        const float cell = 32 * scale;
        const int verticalInset=getHeight()<30?1:4;
        for (int i = 0; i < 3; ++i)
            digits[i].setBounds(4 + roundToInt(i * cell), verticalInset, roundToInt(cell - 2 * scale),
                                getHeight() - 2*verticalInset);
        const int buttonX = 4 + roundToInt(cell * 3 + scale);
        start.setBounds(buttonX, verticalInset, getWidth() - buttonX - 4, getHeight() - 2*verticalInset);
    }
    void mouseDown(const MouseEvent &e) override {
        if (e.mods.isPopupMenu() && settings)
            settings();
    }

  private:
    StageState &state;
    std::function<void()> settings;
    TextEditor digits[3];
    QuietButton start{localization::translate("Iniciar")};
    void timerCallback() override {
        auto parts = StringArray::fromTokens(
            state.timeText().removeCharacters(String::fromUTF8("−")), ":", {});
        for (int i = 0; i < 3; ++i) {
            digits[i].setReadOnly(state.running);
            if (state.running || !digits[i].hasKeyboardFocus(true))
                digits[i].setText(parts[i], false);
        }
        start.setButtonText(localization::translate(state.running ? "Stop" : "Start"));
    }
};
} // namespace catlive
