#pragma once
#include "AudioDevice.h"
#include <memory>

namespace catlive::native::audio {
struct WasapiEndpoint {
    std::wstring id, name;
    Direction direction = Direction::render;
    std::uint32_t state = 0; // Windows DEVICE_STATE_* flags.
    bool defaultConsole = false, defaultMultimedia = false, defaultCommunications = false;
};
struct WasapiCapabilities {
    WasapiEndpoint endpoint;
    SampleFormat mixFormat;
    std::uint64_t defaultPeriod100ns = 0, minimumPeriod100ns = 0;
    bool sharedLowLatency = false;
    std::uint32_t defaultSharedPeriodFrames = 0, fundamentalSharedPeriodFrames = 0,
                  minimumSharedPeriodFrames = 0, maximumSharedPeriodFrames = 0;
};
struct WasapiFormatSupport {
    bool exact = false;
    std::optional<SampleFormat> closestSharedFormat;
    std::uint32_t nativeError = 0;
};
// Windows 10 1703+ (event-driven loopback support). One direction per instance:
// shared/sharedLowLatency/exclusive render or capture, or loopback capture from
// a render endpoint. No synchronized duplex, resampling, or silent mode/device
// fallback. Separate endpoint instances have independent clocks.
class WasapiDevice final : public AudioDevice {
public:
    static constexpr bool supportsSynchronizedDuplex = false;
    static constexpr std::uint32_t maximumChannels = 128, maximumBufferFrames = 65536;
    static std::vector<WasapiEndpoint> enumerate(bool includeInactive = false);
    static WasapiCapabilities inspect(const std::wstring& endpointId);
    static WasapiFormatSupport probeFormat(const std::wstring& endpointId, DeviceMode, const SampleFormat&);
    WasapiDevice();
    ~WasapiDevice() override;
    WasapiDevice(const WasapiDevice&) = delete;
    WasapiDevice& operator=(const WasapiDevice&) = delete;
    void open(const StreamRequest&) override;
    void start(ProcessCallback, void* user) override;
    void stop() noexcept override;
    void close() noexcept override;
    const StreamInfo& info() const noexcept override;
    DeviceStatus status() const noexcept override;
    std::uint32_t consumeDeviceChanges() noexcept override;
private:
    struct Impl;
    std::unique_ptr<Impl> impl;
};
} // namespace catlive::native::audio
