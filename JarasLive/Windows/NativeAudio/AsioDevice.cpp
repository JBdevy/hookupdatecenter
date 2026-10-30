#include "AsioDevice.h"
#include "AsioSampleConversion.h"
#include <algorithm>
#include <atomic>
#include <chrono>
#include <cmath>
#include <cstring>
#include <limits>
#include <mutex>
#include <numeric>
#include <thread>

#if defined(_WIN32) && defined(CATLIVE_HAS_ASIO_SDK) && CATLIVE_HAS_ASIO_SDK
#ifndef NOMINMAX
#define NOMINMAX
#endif
#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#include <windows.h>
#include <objbase.h>
// These are provided by the separately installed/licensed Steinberg SDK.
// No SDK implementation files or global ASIO wrapper are linked.
#include <iasiodrv.h>
#define CATLIVE_ASIO_ENABLED 1
#else
#define CATLIVE_ASIO_ENABLED 0
#endif

namespace catlive::native::audio {
#if CATLIVE_ASIO_ENABLED
namespace {
static_assert(std::atomic<void*>::is_always_lock_free);
static_assert(std::atomic<std::uint32_t>::is_always_lock_free);
static_assert(std::atomic<std::uint64_t>::is_always_lock_free);
static_assert(std::atomic<bool>::is_always_lock_free);
static_assert(std::atomic<DeviceState>::is_always_lock_free);
struct RegistryKey {
    HKEY key = nullptr;
    ~RegistryKey() { if (key) RegCloseKey(key); }
};
[[noreturn]] void fail(const char* operation, long code) {
    throw AudioDeviceError(std::string("ASIO: ") + operation + " (" + std::to_string(code) + ")", static_cast<std::uint32_t>(code));
}
void check(ASIOError result, const char* operation) { if (result != ASE_OK) fail(operation, result); }
std::wstring registryString(HKEY key, const wchar_t* name) {
    DWORD bytes = 0, type = 0;
    if (RegQueryValueExW(key, name, nullptr, &type, nullptr, &bytes) != ERROR_SUCCESS || type != REG_SZ || bytes > 65536) return {};
    std::vector<wchar_t> value(bytes / sizeof(wchar_t) + 1, 0);
    if (RegQueryValueExW(key, name, nullptr, &type, reinterpret_cast<BYTE*>(value.data()), &bytes) != ERROR_SUCCESS || type != REG_SZ) return {};
    return std::wstring(value.data());
}
std::string boundedString(const char* value, std::size_t maximum) {
    const auto end = std::find(value, value + maximum, '\0'); return {value, end};
}
asio_detail::PCMFormat sampleFormat(ASIOSampleType type) {
    using F = asio_detail::PCMFormat;
    switch (type) {
        case ASIOSTInt16LSB: return F{2,16,false,false}; case ASIOSTInt16MSB: return F{2,16,true,false};
        case ASIOSTInt24LSB: return F{3,24,false,false}; case ASIOSTInt24MSB: return F{3,24,true,false};
        case ASIOSTInt32LSB: return F{4,32,false,false}; case ASIOSTInt32MSB: return F{4,32,true,false};
        case ASIOSTFloat32LSB: return F{4,32,false,true}; case ASIOSTFloat32MSB: return F{4,32,true,true};
        case ASIOSTFloat64LSB: return F{8,64,false,true}; case ASIOSTFloat64MSB: return F{8,64,true,true};
        case ASIOSTInt32LSB16: return F{4,16,false,false}; case ASIOSTInt32MSB16: return F{4,16,true,false};
        case ASIOSTInt32LSB18: return F{4,18,false,false}; case ASIOSTInt32MSB18: return F{4,18,true,false};
        case ASIOSTInt32LSB20: return F{4,20,false,false}; case ASIOSTInt32MSB20: return F{4,20,true,false};
        case ASIOSTInt32LSB24: return F{4,24,false,false}; case ASIOSTInt32MSB24: return F{4,24,true,false};
        default: throw AudioDeviceError("ASIO: unsupported sample format; DSD is not a PCM stream.");
    }
}
std::vector<std::uint32_t> channels(const std::vector<std::uint32_t>& requested, std::uint32_t count, bool enabled) {
    if (!enabled) {
        if (!requested.empty()) throw AudioDeviceError("ASIO: channel indices were supplied for a disabled direction.");
        return {};
    }
    auto result = requested;
    if (result.empty()) { result.resize(count); std::iota(result.begin(), result.end(), 0u); }
    std::vector<bool> seen(count, false);
    for (const auto channel : result) {
        if (channel >= count || seen[channel]) throw AudioDeviceError("ASIO: physical channel indices must be valid and unique.");
        seen[channel] = true;
    }
    return result;
}
std::uint32_t chooseBuffer(std::uint32_t requested, long minimum, long maximum, long preferred, long granularity) {
    if (minimum < 1 || maximum < minimum || preferred < minimum || preferred > maximum || granularity < -1)
        throw AudioDeviceError("ASIO: invalid driver buffer-size limits.");
    const auto value = requested ? static_cast<std::uint64_t>(requested) : static_cast<std::uint64_t>(preferred);
    if (value < static_cast<std::uint64_t>(minimum) || value > static_cast<std::uint64_t>(maximum) || value > AsioDevice::maximumBufferFrames)
        throw AudioDeviceError("ASIO: requested buffer size is outside supported limits.");
    if ((granularity == -1 && (value & (value - 1))) || (granularity == 0 && value != static_cast<std::uint64_t>(preferred)) ||
        (granularity > 0 && (value - static_cast<std::uint64_t>(minimum)) % static_cast<std::uint64_t>(granularity)))
        throw AudioDeviceError("ASIO: requested buffer size does not match driver granularity.");
    return static_cast<std::uint32_t>(value);
}
template<class Integer>
std::uint64_t asioInteger(const Integer& value) noexcept {
#if NATIVE_INT64
    return static_cast<std::uint64_t>(value);
#else
    return (std::uint64_t(value.hi) << 32) | value.lo;
#endif
}
std::uint64_t rateBits(double value) noexcept { std::uint64_t bits; std::memcpy(&bits, &value, sizeof(bits)); return bits; }
double bitsRate(std::uint64_t bits) noexcept { double value; std::memcpy(&value, &bits, sizeof(value)); return value; }
} // namespace

struct AsioDevice::Impl {
    static std::mutex ownershipMutex;
    static Impl* owner; // Only accessed under ownershipMutex, on control calls.
    static std::atomic<Impl*> callbackTarget;
    static std::atomic<std::uint32_t> callbackReaders;
    struct Lease {
        Impl* target;
        Lease() noexcept {
            // Increment before loading the pointer. close clears the pointer,
            // then drains readers before freeing any callback-visible storage.
            callbackReaders.fetch_add(1, std::memory_order_seq_cst);
            target = callbackTarget.load(std::memory_order_seq_cst);
        }
        ~Lease() { callbackReaders.fetch_sub(1, std::memory_order_seq_cst); }
    };
    void* window = nullptr;
    IASIO* driver = nullptr;
    DWORD controlThread = 0;
    bool ownsCOM = false, buffersCreated = false, postOutput = false, startAttempted = false;
    StreamInfo stream;
    AsioCapabilities caps;
    std::vector<ASIOBufferInfo> buffers;
    std::vector<asio_detail::Converter> conversions;
    std::vector<float> inputStorage, outputStorage;
    std::vector<float*> inputWritable, outputPointers;
    std::vector<const float*> inputPointers;
    std::uint32_t nativeInputs = 0, nativeOutputs = 0;
    ProcessCallback process = nullptr;
    void* user = nullptr;
    ASIOCallbacks callbacks{};
    std::atomic<DeviceState> state{DeviceState::closed};
    std::atomic<bool> processing{false};
    std::atomic<bool> buffersReady{false};
    std::atomic_flag rendering = ATOMIC_FLAG_INIT;
    std::atomic<std::uint32_t> changes{0}, nativeError{0}, blockFlags{0};
    std::atomic<std::uint64_t> callbackCount{0}, frameCount{0}, dropouts{0}, changedRate{0};
    std::atomic<std::uint64_t> configurationEpoch{0};
    std::uint64_t nextFrame = 0; // Only the serialized buffer callback owns this.
    double qpcTo100ns = 0;

    explicit Impl(void* value) : window(value) {}
    void requireThread() const {
        if (controlThread && controlThread != GetCurrentThreadId()) fail("control call must use the opening thread", RPC_E_WRONG_THREAD);
    }
    static void drain() noexcept {
        // This is exclusively a control-thread wait; the callback never waits.
        while (callbackReaders.load(std::memory_order_seq_cst) != 0) std::this_thread::sleep_for(std::chrono::milliseconds(1));
    }
    void invalidate(std::uint32_t reasons) noexcept {
        configurationEpoch.fetch_add(1, std::memory_order_acq_rel);
        changes.fetch_or(reasons, std::memory_order_relaxed);
        processing.store(false, std::memory_order_release);
        state.store(DeviceState::invalidated, std::memory_order_release);
    }
    static void switchBuffer(long index, ASIOBool) noexcept {
        Lease lease; if (lease.target) lease.target->render(index, nullptr);
    }
    static ASIOTime* switchTime(ASIOTime* time, long index, ASIOBool) noexcept {
        Lease lease; if (lease.target) lease.target->render(index, time); return time;
    }
    static void rateChanged(ASIOSampleRate rate) noexcept {
        Lease lease; if (!lease.target) return;
        auto& self = *lease.target;
        if (std::isfinite(rate) && rate > 0) self.changedRate.store(rateBits(rate), std::memory_order_relaxed);
        self.invalidate(sampleRateChanged | formatChanged | resetRequired);
    }
    static long message(long selector, long value, void*, double*) noexcept {
        if (selector == kAsioSelectorSupported) {
            switch (value) {
                case kAsioEngineVersion: case kAsioResetRequest: case kAsioResyncRequest:
                case kAsioLatenciesChanged: case kAsioSupportsTimeInfo: case kAsioOverload: return 1;
                default: return 0;
            }
        }
        if (selector == kAsioEngineVersion) return 2;
        if (selector == kAsioSupportsTimeInfo) return 1;
        Lease lease; if (!lease.target) return 0;
        auto& self = *lease.target;
        switch (selector) {
            case kAsioResetRequest: self.invalidate(resetRequired); return 1;
            case kAsioResyncRequest:
                self.blockFlags.fetch_or(discontinuity, std::memory_order_relaxed);
                self.dropouts.fetch_add(1, std::memory_order_relaxed); self.invalidate(resetRequired); return 1;
            case kAsioLatenciesChanged: self.invalidate(latencyChanged | resetRequired); return 1;
            case kAsioOverload:
                self.dropouts.fetch_add(1, std::memory_order_relaxed); self.changes.fetch_or(driverOverload, std::memory_order_relaxed);
                self.blockFlags.fetch_or(discontinuity, std::memory_order_relaxed); return 1;
            // Buffer-size change negotiation is not implemented by ASIO 2.3;
            // drivers must request reset. Timecode and direct monitoring are not supported.
            default: return 0;
        }
    }
    void render(long index, const ASIOTime* time) noexcept {
        if (index != 0 && index != 1) { nativeError.store(static_cast<std::uint32_t>(ASE_InvalidParameter)); invalidate(resetRequired); return; }
        // A driver must serialize buffer callbacks. A broken/reentrant driver
        // is invalidated immediately; no second callback touches shared planes.
        if (rendering.test_and_set(std::memory_order_acquire)) {
            dropouts.fetch_add(1, std::memory_order_relaxed); invalidate(driverOverload | resetRequired); return;
        }
        struct Release { std::atomic_flag& flag; ~Release() { flag.clear(std::memory_order_release); } } release{rendering};
        if (!buffersReady.load(std::memory_order_acquire)) return;
        const auto frames = stream.bufferFrames;
        for (std::uint32_t physical = 0; physical < nativeOutputs; ++physical) {
            const auto channel = nativeInputs + physical;
            std::memset(buffers[channel].buffers[index], 0, std::size_t(frames) * conversions[channel].bytes);
        }
        if (!processing.load(std::memory_order_acquire)) return;
        for (std::size_t channel = 0; channel < inputPointers.size(); ++channel) {
            const auto physical = stream.inputChannelIndices[channel];
            // ASIO specifies that the first input buffer after start is invalid.
            if (nextFrame == 0) std::fill_n(inputWritable[channel], frames, 0.f);
            else conversions[physical].decode(inputWritable[channel], buffers[physical].buffers[index], frames);
        }
        std::fill(outputStorage.begin(), outputStorage.end(), 0.f);
        AudioBlock block;
        block.inputs = inputPointers.data(); block.outputs = outputPointers.data();
        block.inputChannels = stream.inputChannels; block.outputChannels = stream.outputChannels;
        block.frames = frames; block.sampleRate = stream.sampleRate; block.framePosition = nextFrame;
        block.flags = blockFlags.exchange(0, std::memory_order_relaxed);
        if (nextFrame == 0) block.flags |= priming | silentInput;
        if (inputPointers.empty()) block.flags |= silentInput;
        LARGE_INTEGER qpc{};
        if (QueryPerformanceCounter(&qpc) && qpc.QuadPart >= 0) {
            block.qpcTime100ns = static_cast<std::uint64_t>(double(qpc.QuadPart) * qpcTo100ns);
            block.flags |= timestampValid | timestampEstimated;
        }
        if (time) {
            const auto flags = time->timeInfo.flags;
            if (flags & kSamplePositionValid) block.framePosition = asioInteger(time->timeInfo.samplePosition);
            if (flags & kSystemTimeValid) {
                block.deviceTimeNanoseconds = asioInteger(time->timeInfo.systemTime);
                block.flags |= deviceTimestampValid;
            }
            if (flags & (kSampleRateChanged | kClockSourceChanged)) {
                if ((flags & kSampleRateValid) && std::isfinite(time->timeInfo.sampleRate) && time->timeInfo.sampleRate > 0)
                    changedRate.store(rateBits(time->timeInfo.sampleRate), std::memory_order_relaxed);
                invalidate(sampleRateChanged | formatChanged | resetRequired); return;
            }
        } else block.flags |= timestampEstimated;
        process(user, block);
        // A reset can arrive on another driver thread while DSP is running.
        // Keep the already-cleared native outputs silent if that happened.
        if (processing.load(std::memory_order_acquire))
            for (std::size_t channel = 0; channel < outputPointers.size(); ++channel) {
                const auto physical = nativeInputs + stream.outputChannelIndices[channel];
                conversions[physical].encode(buffers[physical].buffers[index], outputPointers[channel], frames);
            }
        nextFrame = block.framePosition + frames;
        callbackCount.fetch_add(1, std::memory_order_relaxed); frameCount.fetch_add(frames, std::memory_order_relaxed);
        if (postOutput) {
            const auto result = driver->outputReady();
            if (result != ASE_OK) { nativeError.store(static_cast<std::uint32_t>(result)); invalidate(resetRequired); }
        }
    }
    void stopDriver() noexcept {
        processing.store(false, std::memory_order_release);
        if (driver && startAttempted) {
            const auto result = driver->stop(); startAttempted = false;
            if (result != ASE_OK) { nativeError.store(static_cast<std::uint32_t>(result)); state.store(DeviceState::failed); }
        }
        drain(); process = nullptr; user = nullptr;
        const auto current = state.load();
        if (driver && current != DeviceState::invalidated && current != DeviceState::failed) state.store(DeviceState::stopped);
    }
    void closeDriver() noexcept {
        stopDriver();
        callbackTarget.store(nullptr, std::memory_order_seq_cst); drain();
        buffersReady.store(false, std::memory_order_release);
        if (driver) {
            if (buffersCreated) {
                const auto result = driver->disposeBuffers();
                if (result != ASE_OK) nativeError.store(static_cast<std::uint32_t>(result));
            }
            buffersCreated = false; driver->Release(); driver = nullptr;
        }
        if (ownsCOM && controlThread == GetCurrentThreadId()) CoUninitialize();
        ownsCOM = false; controlThread = 0;
        buffers.clear(); conversions.clear(); inputStorage.clear(); outputStorage.clear();
        inputWritable.clear(); inputPointers.clear(); outputPointers.clear();
        nativeInputs = nativeOutputs = 0; stream = {}; caps = {}; postOutput = false;
        if (owner == this) owner = nullptr;
        state.store(DeviceState::closed, std::memory_order_release);
    }
};
std::mutex AsioDevice::Impl::ownershipMutex;
AsioDevice::Impl* AsioDevice::Impl::owner = nullptr;
std::atomic<AsioDevice::Impl*> AsioDevice::Impl::callbackTarget{nullptr};
std::atomic<std::uint32_t> AsioDevice::Impl::callbackReaders{0};

bool AsioDevice::available() noexcept { return true; }
std::vector<AsioEndpoint> AsioDevice::enumerate() {
    RegistryKey root;
#if defined(_WIN64)
    constexpr REGSAM view = KEY_WOW64_64KEY;
#else
    constexpr REGSAM view = KEY_WOW64_32KEY;
#endif
    const auto result = RegOpenKeyExW(HKEY_LOCAL_MACHINE, L"SOFTWARE\\ASIO", 0, KEY_READ | view, &root.key);
    if (result == ERROR_FILE_NOT_FOUND || result == ERROR_PATH_NOT_FOUND) return {};
    if (result != ERROR_SUCCESS) fail("cannot enumerate registered drivers", result);
    std::vector<AsioEndpoint> endpoints;
    for (DWORD index = 0;; ++index) {
        wchar_t name[256]{}; DWORD length = 256;
        const auto next = RegEnumKeyExW(root.key, index, name, &length, nullptr, nullptr, nullptr, nullptr);
        if (next == ERROR_NO_MORE_ITEMS) break;
        if (next != ERROR_SUCCESS) fail("cannot read registered driver", next);
        RegistryKey entry;
        if (RegOpenKeyExW(root.key, name, 0, KEY_READ | view, &entry.key) != ERROR_SUCCESS) continue;
        const auto id = registryString(entry.key, L"CLSID"); CLSID clsid{};
        if (id.empty() || FAILED(CLSIDFromString(id.c_str(), &clsid))) continue;
        wchar_t canonical[40]{}; if (!StringFromGUID2(clsid, canonical, 40)) continue;
        if (std::any_of(endpoints.begin(), endpoints.end(), [&](const auto& item) { return item.id == canonical; })) continue;
        auto description = registryString(entry.key, L"Description");
        endpoints.push_back({canonical, description.empty() ? std::wstring(name) : std::move(description), name});
    }
    std::sort(endpoints.begin(), endpoints.end(), [](const auto& a, const auto& b) { return a.name < b.name; });
    return endpoints;
}
AsioDevice::AsioDevice(void* window) : impl(std::make_unique<Impl>(window)) {}
AsioDevice::~AsioDevice() { close(); }
void AsioDevice::open(const StreamRequest& request) {
    auto& self = *impl;
    std::lock_guard<std::mutex> lock(Impl::ownershipMutex);
    self.requireThread();
    if (Impl::owner && Impl::owner != &self) throw AudioDeviceError("ASIO: another driver instance is already open.");
    if (self.driver) self.closeDriver();
    if (request.mode != DeviceMode::asio || request.endpointId.empty() || request.format)
        throw AudioDeviceError("ASIO: select an ASIO driver CLSID; a WASAPI wire format cannot be supplied.");
    if (request.sampleRate && (request.sampleRate < 8000 || request.sampleRate > 768000)) throw AudioDeviceError("ASIO: invalid PCM sample rate.");
    CLSID clsid{}; if (FAILED(CLSIDFromString(request.endpointId.c_str(), &clsid))) throw AudioDeviceError("ASIO: invalid driver CLSID.");
    const auto endpoints = enumerate();
    const auto selected = std::find_if(endpoints.begin(), endpoints.end(), [&](const auto& item) { CLSID found{}; return SUCCEEDED(CLSIDFromString(item.id.c_str(), &found)) && IsEqualCLSID(found, clsid); });
    if (selected == endpoints.end()) throw AudioDeviceError("ASIO: driver is not registered for this process architecture.");
    Impl::owner = &self;
    self.nativeError.store(0); self.changes.store(0); self.changedRate.store(0);
    self.callbackCount.store(0); self.frameCount.store(0); self.dropouts.store(0); self.blockFlags.store(0);
    try {
        self.controlThread = GetCurrentThreadId();
        LARGE_INTEGER frequency{};
        if (!QueryPerformanceFrequency(&frequency) || frequency.QuadPart <= 0) throw AudioDeviceError("ASIO: performance clock is unavailable.");
        self.qpcTo100ns = 10000000. / double(frequency.QuadPart);
        const auto com = CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);
        if (FAILED(com)) fail("COM initialization requires an STA control thread", com);
        self.ownsCOM = true;
        const auto created = CoCreateInstance(clsid, nullptr, CLSCTX_INPROC_SERVER, clsid, reinterpret_cast<void**>(&self.driver));
        if (FAILED(created) || !self.driver) fail("cannot create driver", created);
        Impl::callbackTarget.store(&self, std::memory_order_seq_cst);
        if (self.driver->init(self.window) != ASIOTrue) {
            char message[124]{}; self.driver->getErrorMessage(message);
            throw AudioDeviceError("ASIO: driver initialization failed. " + boundedString(message, sizeof(message)));
        }
        char name[32]{}; self.driver->getDriverName(name); self.caps.driverName = boundedString(name, sizeof(name));
        self.caps.driverVersion = static_cast<std::uint32_t>(self.driver->getDriverVersion());
        ASIOSampleRate rate = 0;
        check(self.driver->getSampleRate(&rate), "cannot query sample rate");
        if (request.sampleRate && (!std::isfinite(rate) || std::abs(rate - request.sampleRate) > .01)) {
            check(self.driver->canSampleRate(request.sampleRate), "requested sample rate is unsupported");
            check(self.driver->setSampleRate(request.sampleRate), "cannot set requested sample rate");
            check(self.driver->getSampleRate(&rate), "cannot verify sample rate");
        }
        if (!std::isfinite(rate) || rate < 8000 || rate > 768000 || (request.sampleRate && std::abs(rate - request.sampleRate) > .01))
            throw AudioDeviceError("ASIO: driver did not establish the requested PCM sample rate.");
        self.caps.sampleRates.push_back(rate);
        for (const double candidate : {8000.,11025.,16000.,22050.,32000.,44100.,48000.,88200.,96000.,176400.,192000.,352800.,384000.})
            if (std::abs(candidate-rate)>.01 && self.driver->canSampleRate(candidate)==ASE_OK)
                self.caps.sampleRates.push_back(candidate);
        std::sort(self.caps.sampleRates.begin(),self.caps.sampleRates.end());
        // Synchronous notifications caused by setting the requested rate have
        // now been fulfilled. Preserve every later notification during setup.
        self.changes.store(0); self.changedRate.store(0);
        self.state.store(DeviceState::starting, std::memory_order_release);
        long inputCount = 0, outputCount = 0;
        check(self.driver->getChannels(&inputCount, &outputCount), "cannot query channels");
        if (inputCount < 0 || outputCount < 0 || inputCount > maximumChannels || outputCount > maximumChannels || (!inputCount && !outputCount))
            throw AudioDeviceError("ASIO: driver channel count exceeds the explicit 256-channel capacity per direction.");
        const bool useInput = request.direction != Direction::render, useOutput = request.direction != Direction::capture;
        self.stream.inputChannelIndices = channels(request.inputChannelIndices, static_cast<std::uint32_t>(inputCount), useInput);
        self.stream.outputChannelIndices = channels(request.outputChannelIndices, static_cast<std::uint32_t>(outputCount), useOutput);
        if ((useInput && self.stream.inputChannelIndices.empty()) || (useOutput && self.stream.outputChannelIndices.empty()))
            throw AudioDeviceError("ASIO: the selected driver has no channels for the requested direction.");
        self.nativeInputs = useInput ? static_cast<std::uint32_t>(inputCount) : 0;
        self.nativeOutputs = useOutput ? static_cast<std::uint32_t>(outputCount) : 0;
        long minimum = 0, maximum = 0, preferred = 0, granularity = 0;
        check(self.driver->getBufferSize(&minimum, &maximum, &preferred, &granularity), "cannot query buffer sizes");
        self.stream.bufferFrames = chooseBuffer(request.requestedBufferFrames, minimum, maximum, preferred, granularity);
        self.stream.maximumCallbackFrames = self.stream.periodFrames = self.stream.bufferFrames;
        self.caps.minimumBufferFrames = static_cast<std::uint32_t>(minimum); self.caps.maximumBufferFrames = static_cast<std::uint32_t>(maximum);
        self.caps.preferredBufferFrames = static_cast<std::uint32_t>(preferred); self.caps.bufferGranularity = static_cast<std::int32_t>(granularity);
        self.stream.endpointId = selected->id; self.stream.mode = DeviceMode::asio; self.stream.sampleRate = rate;
        self.stream.inputChannels = static_cast<std::uint32_t>(self.stream.inputChannelIndices.size());
        self.stream.outputChannels = static_cast<std::uint32_t>(self.stream.outputChannelIndices.size());
        for (int direction = 0; direction < 2; ++direction) {
            const auto count = direction == 0 ? inputCount : outputCount;
            auto& described = direction == 0 ? self.caps.inputs : self.caps.outputs;
            for (long channel = 0; channel < count; ++channel) {
                ASIOChannelInfo info{}; info.channel = channel; info.isInput = direction == 0 ? ASIOTrue : ASIOFalse;
                check(self.driver->getChannelInfo(&info), "cannot query channel format");
                const auto format = sampleFormat(info.type);
                described.push_back({boundedString(info.name, sizeof(info.name)), static_cast<std::uint32_t>(channel),
                    format.floatingPoint ? SampleEncoding::floatingPoint : SampleEncoding::signedPCM,
                    static_cast<std::uint16_t>(format.storageBytes * 8), static_cast<std::uint16_t>(format.validBits), format.bigEndian});
                if ((direction == 0 && useInput) || (direction == 1 && useOutput)) {
                    ASIOBufferInfo buffer{}; buffer.isInput = info.isInput; buffer.channelNum = channel;
                    self.buffers.push_back(buffer); self.conversions.push_back(asio_detail::makeConverter(format));
                }
            }
        }
        self.inputStorage.resize(std::size_t(self.stream.inputChannels) * self.stream.bufferFrames, 0.f);
        self.outputStorage.resize(std::size_t(self.stream.outputChannels) * self.stream.bufferFrames, 0.f);
        for (std::uint32_t channel = 0; channel < self.stream.inputChannels; ++channel) {
            auto* plane = self.inputStorage.data() + std::size_t(channel) * self.stream.bufferFrames;
            self.inputWritable.push_back(plane); self.inputPointers.push_back(plane);
        }
        for (std::uint32_t channel = 0; channel < self.stream.outputChannels; ++channel)
            self.outputPointers.push_back(self.outputStorage.data() + std::size_t(channel) * self.stream.bufferFrames);
        self.callbacks = {Impl::switchBuffer, Impl::rateChanged, Impl::message, Impl::switchTime};
        check(self.driver->createBuffers(self.buffers.data(), static_cast<long>(self.buffers.size()), static_cast<long>(self.stream.bufferFrames), &self.callbacks), "cannot create native buffers");
        self.buffersCreated = true;
        for (std::size_t channel = 0; channel < self.buffers.size(); ++channel) {
            const auto& buffer = self.buffers[channel];
            if (!buffer.buffers[0] || !buffer.buffers[1]) throw AudioDeviceError("ASIO: driver returned a null native buffer.");
            if (!buffer.isInput) for (auto* pointer : buffer.buffers)
                std::memset(pointer, 0, std::size_t(self.stream.bufferFrames) * self.conversions[channel].bytes);
        }
        long inputLatency = 0, outputLatency = 0;
        check(self.driver->getLatencies(&inputLatency, &outputLatency), "cannot query stream latencies");
        if (inputLatency < 0 || outputLatency < 0) throw AudioDeviceError("ASIO: driver returned negative latency.");
        self.caps.inputLatencyFrames = static_cast<std::uint32_t>(inputLatency); self.caps.outputLatencyFrames = static_cast<std::uint32_t>(outputLatency);
        self.stream.latency100ns = static_cast<std::uint64_t>(10000000. * double(useOutput ? outputLatency : inputLatency) / rate);
        self.stream.inputLatency100ns = static_cast<std::uint64_t>(10000000. * double(useInput ? inputLatency : 0) / rate);
        // Wire formats may differ per channel. deviceFormat describes the
        // callback's normalized planar floats; capabilities preserves each wire format.
        self.stream.deviceFormat = {SampleEncoding::floatingPoint, static_cast<std::uint32_t>(std::llround(rate)),
            static_cast<std::uint16_t>(useOutput ? self.stream.outputChannels : self.stream.inputChannels), 32, 32, 0};
        self.postOutput = self.nativeOutputs > 0 && self.driver->outputReady() == ASE_OK;
        if (self.changes.load(std::memory_order_acquire) & (resetRequired | sampleRateChanged | formatChanged))
            throw AudioDeviceError("ASIO: driver configuration changed while opening; retry with the new configuration.");
        self.buffersReady.store(true, std::memory_order_release);
        auto expected = DeviceState::starting;
        if (!self.state.compare_exchange_strong(expected, DeviceState::prepared, std::memory_order_release, std::memory_order_relaxed))
            throw AudioDeviceError("ASIO: driver invalidated the stream while opening.");
    } catch (const AudioDeviceError& error) {
        self.closeDriver(); self.nativeError.store(error.nativeCode()); self.state.store(DeviceState::failed, std::memory_order_release); throw;
    } catch (...) {
        self.closeDriver(); self.state.store(DeviceState::failed, std::memory_order_release); throw;
    }
}
void AsioDevice::start(ProcessCallback callback, void* user) {
    auto& self = *impl; std::lock_guard<std::mutex> lock(Impl::ownershipMutex); self.requireThread();
    const auto epoch = self.configurationEpoch.load(std::memory_order_acquire);
    const auto state = self.state.load();
    if (!callback || !self.driver || (state != DeviceState::prepared && state != DeviceState::stopped) ||
        (self.changes.load() & (resetRequired | sampleRateChanged | formatChanged)))
        throw AudioDeviceError("ASIO: start requires a prepared stream and a real-time process callback.");
    auto expectedState = state;
    if (!self.state.compare_exchange_strong(expectedState, DeviceState::starting, std::memory_order_acq_rel))
        throw AudioDeviceError("ASIO: driver configuration changed before start.");
    Impl::drain(); self.process = callback; self.user = user; self.nextFrame = 0;
    for (std::size_t channel = self.nativeInputs; channel < self.buffers.size(); ++channel)
        for (auto* pointer : self.buffers[channel].buffers)
            std::memset(pointer, 0, std::size_t(self.stream.bufferFrames) * self.conversions[channel].bytes);
    self.blockFlags.store(priming); self.processing.store(true, std::memory_order_release);
    if (self.configurationEpoch.load(std::memory_order_acquire) != epoch) {
        self.processing.store(false, std::memory_order_release);
        throw AudioDeviceError("ASIO: driver configuration changed before start.");
    }
    self.startAttempted = true;
    const auto result = self.driver->start();
    if (result != ASE_OK) { self.nativeError.store(static_cast<std::uint32_t>(result)); self.stopDriver(); self.state.store(DeviceState::failed); fail("cannot start stream", result); }
    auto expected = DeviceState::starting;
    self.state.compare_exchange_strong(expected, DeviceState::running, std::memory_order_release, std::memory_order_relaxed);
}
void AsioDevice::stop() noexcept {
    std::lock_guard<std::mutex> lock(Impl::ownershipMutex);
    if (Impl::owner == impl.get()) impl->stopDriver();
}
void AsioDevice::close() noexcept {
    std::lock_guard<std::mutex> lock(Impl::ownershipMutex);
    if (Impl::owner == impl.get()) impl->closeDriver();
    else impl->state.store(DeviceState::closed, std::memory_order_release);
}
void AsioDevice::controlPanel() {
    auto& self = *impl; std::lock_guard<std::mutex> lock(Impl::ownershipMutex); self.requireThread();
    if (!self.driver) throw AudioDeviceError("ASIO: open a driver before showing its control panel.");
    self.stopDriver();
    const auto result = self.driver->controlPanel();
    self.invalidate(resetRequired | formatChanged);
    check(result, "driver control panel is unavailable");
}
const StreamInfo& AsioDevice::info() const noexcept { return impl->stream; }
const AsioCapabilities& AsioDevice::capabilities() const noexcept { return impl->caps; }
DeviceStatus AsioDevice::status() const noexcept {
    return {impl->state.load(std::memory_order_acquire), impl->nativeError.load(), impl->callbackCount.load(), impl->frameCount.load(), impl->dropouts.load(), false};
}
std::uint32_t AsioDevice::consumeDeviceChanges() noexcept { return impl->changes.exchange(0, std::memory_order_acq_rel); }
double AsioDevice::pendingSampleRate() const noexcept { return bitsRate(impl->changedRate.load(std::memory_order_acquire)); }

#else
struct AsioDevice::Impl { StreamInfo stream; AsioCapabilities caps; };
bool AsioDevice::available() noexcept { return false; }
std::vector<AsioEndpoint> AsioDevice::enumerate() { return {}; }
AsioDevice::AsioDevice(void*) : impl(std::make_unique<Impl>()) {}
AsioDevice::~AsioDevice() = default;
void AsioDevice::open(const StreamRequest&) { throw AudioDeviceError("ASIO support was not built with an external Steinberg SDK."); }
void AsioDevice::start(ProcessCallback, void*) { throw AudioDeviceError("ASIO support is unavailable."); }
void AsioDevice::stop() noexcept {}
void AsioDevice::close() noexcept {}
const StreamInfo& AsioDevice::info() const noexcept { return impl->stream; }
const AsioCapabilities& AsioDevice::capabilities() const noexcept { return impl->caps; }
DeviceStatus AsioDevice::status() const noexcept { return {}; }
std::uint32_t AsioDevice::consumeDeviceChanges() noexcept { return 0; }
double AsioDevice::pendingSampleRate() const noexcept { return 0; }
void AsioDevice::controlPanel() { throw AudioDeviceError("ASIO support is unavailable."); }
#endif
} // namespace catlive::native::audio
