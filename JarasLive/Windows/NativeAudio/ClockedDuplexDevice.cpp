#include "ClockedDuplexDevice.h"
#include <cmath>

namespace catlive::native::audio {
ClockedDuplexDevice::ClockedDuplexDevice(std::unique_ptr<AudioDevice> render, std::unique_ptr<AudioDevice> capture)
    : outputDevice(std::move(render)), inputDevice(std::move(capture)) {
    if (!outputDevice || !inputDevice) throw AudioDeviceError("Duplex requires two native endpoints");
}
ClockedDuplexDevice::~ClockedDuplexDevice() { close(); }

void ClockedDuplexDevice::open(const StreamRequest& request) {
    close();
    if (request.direction != Direction::duplex || request.mode == DeviceMode::asio)
        throw AudioDeviceError("Clocked duplex requires WASAPI input and output");
    try {
        auto output = request;
        output.direction = Direction::render;
        output.inputChannelIndices.clear();
        if (output.mode == DeviceMode::loopback) output.mode = DeviceMode::shared;
        outputDevice->open(output);

        StreamRequest input;
        input.direction = Direction::capture;
        input.endpointId = request.inputEndpointId;
        input.mode = request.inputMode.value_or(request.mode);
        if (input.mode == DeviceMode::asio) throw AudioDeviceError("ASIO cannot be a WASAPI capture endpoint");
        if (input.mode == DeviceMode::loopback && input.endpointId.empty())
            input.endpointId = outputDevice->info().endpointId;
        input.sampleRate = request.inputSampleRate;
        input.requestedBufferFrames = request.inputRequestedBufferFrames;
        input.inputChannelIndices = request.inputChannelIndices;
        input.format = request.inputFormat;
        inputDevice->open(input);

        const auto& capture = inputDevice->info();
        stream = outputDevice->info();
        if (!stream.outputChannels || !capture.inputChannels)
            throw AudioDeviceError("Duplex endpoints have no active channels");
        bridge = std::make_unique<DuplexInputBridge>(DuplexInputBridge::Configuration{
            capture.inputChannels, capture.maximumCallbackFrames, stream.maximumCallbackFrames,
            capture.periodFrames, stream.periodFrames, capture.sampleRate, stream.sampleRate});
        stream.inputChannels = capture.inputChannels;
        stream.inputChannelIndices = capture.inputChannelIndices;
        stream.inputLatency100ns = capture.latency100ns + std::uint64_t(std::ceil(
            double(bridge->preparedLatencyFrames()) * 10000000. / capture.sampleRate));
        inputStorage.resize(std::size_t(stream.inputChannels) * stream.maximumCallbackFrames);
        inputPlanes.resize(stream.inputChannels);
        constInputPlanes.resize(stream.inputChannels);
        for (unsigned channel = 0; channel < stream.inputChannels; ++channel) {
            inputPlanes[channel] = inputStorage.data() + std::size_t(channel) * stream.maximumCallbackFrames;
            constInputPlanes[channel] = inputPlanes[channel];
        }
        prepared = true;
        state.store(DeviceState::prepared, std::memory_order_release);
    } catch (...) {
        close();
        throw;
    }
}
void ClockedDuplexDevice::start(ProcessCallback process, void* user) {
    if (!prepared || !process) throw AudioDeviceError("Duplex device is not prepared or callback is missing");
    const auto current = state.load(std::memory_order_acquire);
    if (current == DeviceState::running || current == DeviceState::starting)
        throw AudioDeviceError("Duplex device is already running");
    bridge->reset();
    inputGaps.store(0, std::memory_order_relaxed);
    callback = process; callbackUser = user;
    state.store(DeviceState::starting, std::memory_order_release);
    try {
        inputDevice->start(&captureCallback, this);
        outputDevice->start(&renderCallback, this);
        state.store(DeviceState::running, std::memory_order_release);
    } catch (...) {
        // Even a failed start may have launched a callback. Join both before
        // clearing its context or allowing the caller to destroy the client.
        outputDevice->stop(); inputDevice->stop();
        callback = nullptr; callbackUser = nullptr;
        bridge->reset();
        state.store(DeviceState::failed, std::memory_order_release);
        throw;
    }
}
void ClockedDuplexDevice::stop() noexcept {
    outputDevice->stop();
    inputDevice->stop();
    callback = nullptr; callbackUser = nullptr;
    if (bridge) bridge->reset();
    state.store(prepared ? DeviceState::stopped : DeviceState::closed, std::memory_order_release);
}
void ClockedDuplexDevice::close() noexcept {
    stop();
    inputDevice->close(); outputDevice->close();
    bridge.reset(); inputStorage.clear(); inputPlanes.clear(); constInputPlanes.clear();
    stream = {}; prepared = false;
    changes.store(0, std::memory_order_relaxed);
    inputGaps.store(0, std::memory_order_relaxed);
    state.store(DeviceState::closed, std::memory_order_release);
}
DeviceStatus ClockedDuplexDevice::status() const noexcept {
    auto result = outputDevice->status();
    const auto capture = inputDevice->status();
    result.state = state.load(std::memory_order_acquire);
    if (result.state == DeviceState::running) {
        const auto outputState = outputDevice->status().state;
        if (outputState == DeviceState::invalidated || outputState == DeviceState::failed) result.state = outputState;
        else if (capture.state == DeviceState::invalidated || capture.state == DeviceState::failed) {
            result.state = capture.state; result.nativeError = capture.nativeError;
        }
    }
    result.discontinuities += inputGaps.load(std::memory_order_relaxed);
    result.mmcssActive = result.mmcssActive && capture.mmcssActive;
    return result;
}
std::uint32_t ClockedDuplexDevice::consumeDeviceChanges() noexcept {
    return changes.exchange(0, std::memory_order_acq_rel) |
        outputDevice->consumeDeviceChanges() | inputDevice->consumeDeviceChanges();
}
void ClockedDuplexDevice::captureCallback(void* context, const AudioBlock& block) noexcept {
    auto& self = *static_cast<ClockedDuplexDevice*>(context);
    const bool valid = block.inputChannels == self.stream.inputChannels;
    self.bridge->push(valid && !(block.flags & silentInput) ? block.inputs : nullptr,
                      block.frames, !valid || (block.flags & discontinuity));
    if (!valid) self.changes.fetch_or(resetRequired, std::memory_order_relaxed);
}
void ClockedDuplexDevice::renderCallback(void* context, const AudioBlock& output) noexcept {
    auto& self = *static_cast<ClockedDuplexDevice*>(context);
    if (output.frames > self.stream.maximumCallbackFrames || output.outputChannels != self.stream.outputChannels) {
        self.changes.fetch_or(resetRequired, std::memory_order_relaxed);
        return; // Native endpoint has already cleared output storage.
    }
    auto block = output;
    const auto result = self.bridge->pull(self.inputPlanes.data(), block.frames);
    block.inputs = self.constInputPlanes.data(); block.inputChannels = self.stream.inputChannels;
    block.flags &= ~std::uint32_t(silentInput);
    if (!result.frames) block.flags |= silentInput;
    if (result.discontinuity) {
        block.flags |= discontinuity;
        self.inputGaps.fetch_add(1, std::memory_order_relaxed);
    }
    self.callback(self.callbackUser, block);
}
} // namespace catlive::native::audio
