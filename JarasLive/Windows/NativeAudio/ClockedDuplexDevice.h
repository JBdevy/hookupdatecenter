#pragma once
#include "AudioDevice.h"
#include "DuplexInputBridge.h"
#include <atomic>
#include <memory>

namespace catlive::native::audio {
// Joins independent WASAPI endpoints without driving the graph twice. Only the
// render callback invokes the client. Capture fills a bounded, prepared SPSC
// bridge; clock recovery never waits for input or allocates on either callback.
// ASIO must use its driver's synchronized duplex callback instead of this class.
class ClockedDuplexDevice final : public AudioDevice {
public:
    ClockedDuplexDevice(std::unique_ptr<AudioDevice> render, std::unique_ptr<AudioDevice> capture);
    ~ClockedDuplexDevice() override;
    void open(const StreamRequest&) override;
    void start(ProcessCallback, void*) override;
    void stop() noexcept override;
    void close() noexcept override;
    const StreamInfo& info() const noexcept override { return stream; }
    DeviceStatus status() const noexcept override;
    std::uint32_t consumeDeviceChanges() noexcept override;
private:
    static void captureCallback(void*, const AudioBlock&) noexcept;
    static void renderCallback(void*, const AudioBlock&) noexcept;
    std::unique_ptr<AudioDevice> outputDevice, inputDevice;
    std::unique_ptr<DuplexInputBridge> bridge;
    StreamInfo stream;
    std::vector<float> inputStorage;
    std::vector<float*> inputPlanes;
    std::vector<const float*> constInputPlanes;
    ProcessCallback callback = nullptr;
    void* callbackUser = nullptr;
    bool prepared = false;
    std::atomic<DeviceState> state{DeviceState::closed};
    std::atomic<std::uint32_t> changes{0};
    std::atomic<std::uint64_t> inputGaps{0};
};
} // namespace catlive::native::audio
