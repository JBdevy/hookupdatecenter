#pragma once
#include "DesktopUpdatePolicy.h"
#include <juce_core/juce_core.h>
#include <juce_events/juce_events.h>
#include <cstring>
#include <memory>

namespace catlive {
// Shared by every caption/project tab. All observable state belongs to the
// message thread; the anonymous worker retains no component or service pointer.
class DesktopUpdateService final : public juce::ChangeBroadcaster, private juce::Timer {
  public:
    DesktopUpdateService() : delivery(std::make_shared<Delivery>()) {
        delivery->owner = this;
        startTimer(1);
    }
    ~DesktopUpdateService() override {
        stopTimer();
        delivery->owner = nullptr;
        delivery.reset();
    }
    const std::optional<desktopUpdate::Notice> &available() const { return notice; }
    void openInBrowser() const {
        if (notice && desktopUpdate::browserURL(notice->url))
            juce::URL::createWithoutParsing(juce::String::fromUTF8(notice->url.c_str())).launchInDefaultBrowser();
    }
    static desktopUpdate::Response parse(const juce::String &installed, int status, const juce::String &body) {
        if (status != 200 || body.getNumBytesAsUTF8() > maximumPayload || !desktopUpdate::completeJSONObject(body.toStdString())) return {};
        juce::var json;
        if (juce::JSON::parse(body, json).failed() || !json.isObject()) return {};
        const auto enabled = json["enabled"], published = json["version"], link = json["url"];
        const auto current = installed.toStdString(), release = published.toString().toStdString(), url = link.toString().toStdString();
        return desktopUpdate::evaluate(current, status,
            enabled.isBool() ? std::optional<bool>(static_cast<bool>(enabled)) : std::nullopt,
            published.isString() ? std::optional<std::string_view>(release) : std::nullopt,
            link.isString() ? std::optional<std::string_view>(url) : std::nullopt);
    }
    static desktopUpdate::Response parseBytes(const juce::String &installed, int status, const juce::MemoryBlock &bytes) {
        const auto *raw = static_cast<const char *>(bytes.getData());
        if (bytes.getSize() == 0 || bytes.getSize() > maximumPayload ||
            std::memchr(raw, 0, bytes.getSize()) != nullptr ||
            !juce::CharPointer_UTF8::isValidString(raw, static_cast<int>(bytes.getSize()))) return {};
        return parse(installed, status, juce::String::fromUTF8(raw, static_cast<int>(bytes.getSize())));
    }

  private:
    struct Delivery { DesktopUpdateService *owner = nullptr; };
    static constexpr int maximumPayload = 16 * 1024;
    std::shared_ptr<Delivery> delivery;
    std::optional<desktopUpdate::Notice> notice;
    bool inFlight = false;
    void timerCallback() override {
        stopTimer();
        if (inFlight) return;
        const auto installed = juce::String(JUCE_APPLICATION_VERSION_STRING);
        const auto publicVersion = desktopUpdate::publicVersion(installed.toStdString());
        if (publicVersion.empty()) return;
        inFlight = true;
        const std::weak_ptr<Delivery> target = delivery;
        if (!juce::Thread::launch(juce::Thread::Priority::background, [target, installed, publicVersion] {
            desktopUpdate::Response response;
            try {
                int status = 0;
                auto stream = juce::URL("https://backcatlive.up.railway.app/api/desktop-update")
                    .withParameter("platform", "windows")
                    .withParameter("version", juce::String::fromUTF8(publicVersion.c_str()))
                    .createInputStream(juce::URL::InputStreamOptions(juce::URL::ParameterHandling::inAddress)
                        .withHttpRequestCmd("GET").withConnectionTimeoutMs(5000)
                        .withNumRedirectsToFollow(0).withStatusCode(&status)
                        .withExtraHeaders("Accept: application/json\r\nCache-Control: no-cache\r\n"));
                if (stream && status == 200) {
                    juce::MemoryBlock bytes;
                    const auto deadline = juce::Time::getMillisecondCounterHiRes() + 5000;
                    char buffer[2048];
                    bool complete = true;
                    while (!stream->isExhausted()) {
                        if (juce::Time::getMillisecondCounterHiRes() >= deadline || bytes.getSize() > maximumPayload) { complete = false; break; }
                        const auto count = stream->read(buffer, static_cast<int>(std::min<std::size_t>(sizeof(buffer), maximumPayload + 1 - bytes.getSize())));
                        if (count <= 0) break;
                        bytes.append(buffer, static_cast<std::size_t>(count));
                    }
                    if (complete && bytes.getSize() <= maximumPayload && juce::Time::getMillisecondCounterHiRes() < deadline)
                        response = parseBytes(installed, status, bytes);
                }
            } catch (...) { /* A failed check leaves the last valid notice visible. */ }
            juce::MessageManager::callAsync([target, response = std::move(response)] {
                if (const auto token = target.lock(); token && token->owner) token->owner->completed(response);
            });
        })) completed({});
    }
    void completed(const desktopUpdate::Response &response) {
        inFlight = false;
        if (desktopUpdate::apply(notice, response)) sendChangeMessage();
        startTimer(response.valid ? 5 * 60 * 1000 : 60 * 1000);
    }
};
} // namespace catlive
