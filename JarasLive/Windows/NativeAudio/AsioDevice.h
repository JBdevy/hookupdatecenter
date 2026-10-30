#pragma once
#include "AudioDevice.h"
#include <memory>

namespace catlive::native::audio {
struct AsioEndpoint {
    std::wstring id, name, registryName; // id is the registered CLSID string.
};
struct AsioChannel {
    std::string name;
    std::uint32_t physicalIndex = 0;
    SampleEncoding encoding = SampleEncoding::signedPCM;
    std::uint16_t containerBits = 0, validBits = 0;
    bool bigEndian = false;
};
struct AsioCapabilities {
    std::string driverName;
    std::uint32_t driverVersion = 0;
    std::vector<AsioChannel> inputs, outputs;
    std::uint32_t minimumBufferFrames = 0, maximumBufferFrames = 0, preferredBufferFrames = 0;
    std::int32_t bufferGranularity = 0; // -1: powers of two; 0: fixed; positive: step.
    std::uint32_t inputLatencyFrames = 0, outputLatencyFrames = 0;
    std::vector<double> sampleRates;
};
// Requires CATLIVE_HAS_ASIO_SDK=1 and the *external* licensed SDK common include
// path. Without that definition, enumeration is empty and open reports that
// ASIO is unavailable. This header contains no SDK or Windows declarations.
//
// Control calls and destruction belong to the opening COM/control thread.
// Exactly one live driver instance is permitted because IASIO callbacks carry
// no user context. Driver stop/dispose must honor the ASIO callback contract.
class AsioDevice final : public AudioDevice {
public:
    static constexpr bool supportsSynchronizedDuplex = true;
    static constexpr std::uint32_t maximumChannels = 256, maximumBufferFrames = 65536;
    static bool available() noexcept;
    // Enumerates only drivers registered for this process architecture; does not
    // load them, open hardware, or claim that a registered driver is functional.
    static std::vector<AsioEndpoint> enumerate();
    explicit AsioDevice(void* ownerWindow = nullptr);
    ~AsioDevice() override;
    AsioDevice(const AsioDevice&) = delete;
    AsioDevice& operator=(const AsioDevice&) = delete;
    void open(const StreamRequest&) override;
    void start(ProcessCallback, void* user) override;
    void stop() noexcept override;
    void close() noexcept override;
    const StreamInfo& info() const noexcept override;
    const AsioCapabilities& capabilities() const noexcept;
    DeviceStatus status() const noexcept override;
    std::uint32_t consumeDeviceChanges() noexcept override;
    double pendingSampleRate() const noexcept;
    // Stops processing before opening the driver panel. Call close/open after
    // the panel returns; a driver may have changed buffers/channels/clock.
    void controlPanel();
private:
    struct Impl;
    std::unique_ptr<Impl> impl;
};
} // namespace catlive::native::audio
