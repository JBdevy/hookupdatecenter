#pragma once
#include <cstdint>
#include <optional>
#include <stdexcept>
#include <string>
#include <utility>
#include <vector>

namespace catlive::native::audio {
enum class Direction { render, capture, duplex };
enum class DeviceMode { shared, sharedLowLatency, exclusive, loopback, asio };
using WasapiMode = DeviceMode;
enum class SampleEncoding { signedPCM, unsignedPCM, floatingPoint };
struct SampleFormat {
    SampleEncoding encoding = SampleEncoding::floatingPoint;
    std::uint32_t sampleRate = 0;
    std::uint16_t channels = 0, containerBits = 32, validBits = 32;
    std::uint32_t channelMask = 0;
};
enum class DeviceState { closed, prepared, starting, running, stopped, invalidated, failed };
enum DeviceChange : std::uint32_t {
    devicesChanged = 1u << 0, defaultDeviceChanged = 1u << 1,
    formatChanged = 1u << 2, endpointInvalidated = 1u << 3,
    resetRequired = 1u << 4, sampleRateChanged = 1u << 5,
    latencyChanged = 1u << 6, driverOverload = 1u << 7
};
enum BlockFlag : std::uint32_t {
    discontinuity = 1u << 0, silentInput = 1u << 1,
    timestampValid = 1u << 2, timestampEstimated = 1u << 3,
    priming = 1u << 4, deviceTimestampValid = 1u << 5
};
struct AudioBlock {
    const float* const* inputs = nullptr;
    float* const* outputs = nullptr;
    std::uint32_t inputChannels = 0, outputChannels = 0, frames = 0;
    double sampleRate = 0;
    std::uint64_t framePosition = 0;
    // QPC clock expressed in 100 ns units; use timestampValid before reading.
    // timestampEstimated distinguishes callback/render estimates from capture
    // hardware timestamps. This value is not wall-clock/UTC time.
    std::uint64_t qpcTime100ns = 0;
    // Optional timestamp in the driver's own clock domain, not the QPC epoch.
    std::uint64_t deviceTimeNanoseconds = 0;
    std::uint32_t flags = 0;
};
// Invoked on the device's audio thread. Storage lasts only for this call.
// The callback must not allocate, block, throw, or call device control methods.
// Outputs are cleared before the callback; inactive physical outputs are silent.
using ProcessCallback = void (*)(void* user, const AudioBlock&) noexcept;

struct StreamRequest {
    std::wstring endpointId; // Empty selects the default endpoint for WASAPI.
    Direction direction = Direction::render;
    DeviceMode mode = DeviceMode::shared;
    std::uint32_t sampleRate = 0; // Zero keeps the endpoint/driver default.
    std::uint32_t requestedBufferFrames = 0;
    // Empty selects every physical channel for an enabled direction. Indices
    // are zero-based physical channels, in the desired packed callback order.
    std::vector<std::uint32_t> inputChannelIndices, outputChannelIndices;
    // WASAPI wire format. ASIO obtains per-channel wire formats from its driver.
    std::optional<SampleFormat> format;
    // Independent capture endpoint for a clocked WASAPI duplex device. ASIO
    // already has one synchronized clock and does not use these fields.
    std::wstring inputEndpointId;
    std::uint32_t inputSampleRate = 0;
    std::optional<SampleFormat> inputFormat;
    std::optional<DeviceMode> inputMode;
    std::uint32_t inputRequestedBufferFrames = 0;
};
struct StreamInfo {
    std::wstring endpointId;
    DeviceMode mode = DeviceMode::shared;
    double sampleRate = 0;
    std::uint32_t inputChannels = 0, outputChannels = 0;
    std::vector<std::uint32_t> inputChannelIndices, outputChannelIndices;
    std::uint32_t maximumCallbackFrames = 0, bufferFrames = 0, periodFrames = 0;
    std::uint64_t latency100ns = 0;
    SampleFormat deviceFormat;
    std::uint64_t inputLatency100ns = 0;
};
struct DeviceStatus {
    DeviceState state = DeviceState::closed;
    std::uint32_t nativeError = 0;
    std::uint64_t callbacks = 0, frames = 0, discontinuities = 0;
    bool mmcssActive = false;
};
class AudioDeviceError : public std::runtime_error {
public:
    AudioDeviceError(std::string message, std::uint32_t code = 0)
        : std::runtime_error(std::move(message)), code_(code) {}
    std::uint32_t nativeCode() const noexcept { return code_; }
private:
    std::uint32_t code_;
};
class AudioDevice {
public:
    virtual ~AudioDevice() = default;
    // Control calls are serialized on a non-audio thread. open/start may throw.
    // stop joins the active callback before returning; close also releases the
    // endpoint/driver. No user callback is invoked after stop/close returns.
    virtual void open(const StreamRequest&) = 0;
    virtual void start(ProcessCallback, void* user) = 0;
    virtual void stop() noexcept = 0;
    virtual void close() noexcept = 0;
    // Immutable from successful open until close. Read on the control thread.
    virtual const StreamInfo& info() const noexcept = 0;
    // Pollable without locks; nativeError is an HRESULT or driver status code.
    virtual DeviceStatus status() const noexcept = 0;
    virtual std::uint32_t consumeDeviceChanges() noexcept = 0;
};
} // namespace catlive::native::audio
