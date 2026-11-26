#include "WasapiDevice.h"
#include "PCMConversion.h"
#ifndef NOMINMAX
#define NOMINMAX
#endif
#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#include <windows.h>
// Materialize SDK DEFINE_PROPERTYKEY values in this translation unit; uuid.lib
// does not provide PKEY_AudioEngine_DeviceFormat on every Windows SDK release.
#include <initguid.h>
#include <audioclient.h>
#include <avrt.h>
#include <mmdeviceapi.h>
#include <mmreg.h>
#include <functiondiscoverykeys_devpkey.h>
#include <wrl/client.h>
#include <algorithm>
#include <array>
#include <atomic>
#include <cmath>
#include <cstring>
#include <cwchar>
#include <limits>
#include <mutex>
#include <numeric>
#include <sstream>
#include <thread>

namespace catlive::native::audio {
namespace {
using Microsoft::WRL::ComPtr;
constexpr GUID pcmSubtype{1, 0, 0x0010, {0x80, 0x00, 0x00, 0xaa, 0x00, 0x38, 0x9b, 0x71}};
constexpr GUID floatSubtype{3, 0, 0x0010, {0x80, 0x00, 0x00, 0xaa, 0x00, 0x38, 0x9b, 0x71}};
static_assert(std::atomic<std::uint64_t>::is_always_lock_free);
static_assert(std::atomic<std::uint32_t>::is_always_lock_free);

std::string failureText(const char* operation, HRESULT result) {
    std::ostringstream text;
    text << operation << " (HRESULT 0x" << std::hex << static_cast<std::uint32_t>(result) << ')';
    return text.str();
}
void require(HRESULT result, const char* operation) {
    if (FAILED(result)) throw AudioDeviceError(failureText(operation, result), static_cast<std::uint32_t>(result));
}
struct Apartment {
    HRESULT result = CoInitializeEx(nullptr, COINIT_MULTITHREADED);
    explicit Apartment(bool requireMTA = false) {
        if (FAILED(result) && (requireMTA || result != RPC_E_CHANGED_MODE)) require(result, "Cannot initialize COM for WASAPI");
    }
    ~Apartment() { if (SUCCEEDED(result)) CoUninitialize(); }
};
template <typename T> struct CoMemory {
    T* value = nullptr;
    ~CoMemory() { CoTaskMemFree(value); }
};
struct EventHandle {
    HANDLE value = nullptr;
    explicit EventHandle(bool manual = false) : value(CreateEventW(nullptr, manual, FALSE, nullptr)) {
        if (!value) require(HRESULT_FROM_WIN32(GetLastError()), "Cannot create a WASAPI event");
    }
    ~EventHandle() { if (value) CloseHandle(value); }
    EventHandle(const EventHandle&) = delete;
    EventHandle& operator=(const EventHandle&) = delete;
};
ComPtr<IMMDeviceEnumerator> enumerator() {
    ComPtr<IMMDeviceEnumerator> result;
    require(CoCreateInstance(__uuidof(MMDeviceEnumerator), nullptr, CLSCTX_ALL, IID_PPV_ARGS(result.GetAddressOf())),
            "Cannot enumerate Windows audio endpoints");
    return result;
}
ComPtr<IAudioClient> activate(IMMDevice* endpoint) {
    ComPtr<IAudioClient> result;
    require(endpoint->Activate(__uuidof(IAudioClient), CLSCTX_ALL, nullptr,
                             reinterpret_cast<void**>(result.GetAddressOf())), "Cannot activate the WASAPI endpoint");
    return result;
}
std::wstring endpointID(IMMDevice* endpoint) {
    CoMemory<wchar_t> id;
    require(endpoint->GetId(&id.value), "Cannot identify the WASAPI endpoint");
    return id.value ? id.value : L"";
}
WasapiEndpoint describe(IMMDevice* endpoint) {
    WasapiEndpoint result;
    result.id = endpointID(endpoint);
    DWORD state = 0;
    require(endpoint->GetState(&state), "Cannot read the audio endpoint state");
    result.state = state;
    ComPtr<IMMEndpoint> endpointInterface;
    require(endpoint->QueryInterface(IID_PPV_ARGS(endpointInterface.GetAddressOf())), "Cannot read the endpoint direction");
    EDataFlow flow = eAll;
    require(endpointInterface->GetDataFlow(&flow), "Cannot read the endpoint direction");
    result.direction = flow == eCapture ? Direction::capture : Direction::render;
    ComPtr<IPropertyStore> properties;
    if (SUCCEEDED(endpoint->OpenPropertyStore(STGM_READ, properties.GetAddressOf()))) {
        PROPVARIANT name{};
        if (SUCCEEDED(properties->GetValue(PKEY_Device_FriendlyName, &name)) && name.vt == VT_LPWSTR && name.pwszVal)
            result.name = name.pwszVal;
        PropVariantClear(&name);
    }
    if (result.name.empty()) result.name = result.id;
    return result;
}
SampleFormat parseFormat(const WAVEFORMATEX* wave) {
    if (!wave) throw AudioDeviceError("The endpoint returned no audio format.", E_POINTER);
    SampleFormat result;
    result.sampleRate = wave->nSamplesPerSec;
    result.channels = wave->nChannels;
    result.containerBits = result.validBits = wave->wBitsPerSample;
    WORD kind = wave->wFormatTag;
    if (kind == WAVE_FORMAT_EXTENSIBLE) {
        if (wave->cbSize < sizeof(WAVEFORMATEXTENSIBLE) - sizeof(WAVEFORMATEX))
            throw AudioDeviceError("The endpoint returned a truncated extensible audio format.", E_INVALIDARG);
        const auto* extended = reinterpret_cast<const WAVEFORMATEXTENSIBLE*>(wave);
        result.validBits = extended->Samples.wValidBitsPerSample;
        result.channelMask = extended->dwChannelMask;
        if (IsEqualGUID(extended->SubFormat, pcmSubtype)) kind = WAVE_FORMAT_PCM;
        else if (IsEqualGUID(extended->SubFormat, floatSubtype)) kind = WAVE_FORMAT_IEEE_FLOAT;
        else throw AudioDeviceError("The endpoint requires an unsupported encoded audio format.", AUDCLNT_E_UNSUPPORTED_FORMAT);
    }
    if (kind == WAVE_FORMAT_IEEE_FLOAT) result.encoding = SampleEncoding::floatingPoint;
    else if (kind == WAVE_FORMAT_PCM) result.encoding = result.containerBits == 8 ? SampleEncoding::unsignedPCM : SampleEncoding::signedPCM;
    else throw AudioDeviceError("The endpoint requires an unsupported audio encoding.", AUDCLNT_E_UNSUPPORTED_FORMAT);
    if (!detail::PCMConversion::supports(result) || !result.sampleRate ||
        wave->nBlockAlign != result.channels * (result.containerBits / 8))
        throw AudioDeviceError("The endpoint returned unsupported PCM dimensions.", AUDCLNT_E_UNSUPPORTED_FORMAT);
    return result;
}
WAVEFORMATEXTENSIBLE makeFormat(const SampleFormat& format) {
    const std::uint64_t frameBytes = std::uint64_t(format.channels) * (format.containerBits / 8);
    if (!detail::PCMConversion::supports(format) || format.sampleRate < 1000 || format.sampleRate > 768000 ||
        frameBytes * format.sampleRate > std::numeric_limits<DWORD>::max())
        throw AudioDeviceError("Invalid PCM sample rate, channel count or bit depth.", E_INVALIDARG);
    WAVEFORMATEXTENSIBLE wave{};
    wave.Format.wFormatTag = WAVE_FORMAT_EXTENSIBLE;
    wave.Format.nSamplesPerSec = format.sampleRate;
    wave.Format.nChannels = format.channels;
    wave.Format.wBitsPerSample = format.containerBits;
    wave.Format.nBlockAlign = static_cast<WORD>(frameBytes);
    wave.Format.nAvgBytesPerSec = static_cast<DWORD>(frameBytes * format.sampleRate);
    wave.Format.cbSize = sizeof(WAVEFORMATEXTENSIBLE) - sizeof(WAVEFORMATEX);
    wave.Samples.wValidBitsPerSample = format.validBits;
    wave.dwChannelMask = format.channelMask;
    wave.SubFormat = format.encoding == SampleEncoding::floatingPoint ? floatSubtype : pcmSubtype;
    return wave;
}
WasapiFormatSupport probe(IAudioClient* client, DeviceMode mode, const SampleFormat& format,
                          WAVEFORMATEXTENSIBLE* accepted = nullptr) {
    auto wave = makeFormat(format);
    CoMemory<WAVEFORMATEX> closest;
    const bool exclusive = mode == DeviceMode::exclusive;
    HRESULT result = client->IsFormatSupported(exclusive ? AUDCLNT_SHAREMODE_EXCLUSIVE : AUDCLNT_SHAREMODE_SHARED,
        &wave.Format, exclusive ? nullptr : &closest.value);
    // Some mono/stereo drivers accept only the legacy representation of the
    // same PCM format. Do not silently substitute a different wire format.
    const bool legacyMask = format.channelMask == 0 ||
        (format.channels == 1 && format.channelMask == SPEAKER_FRONT_CENTER) ||
        (format.channels == 2 && format.channelMask == (SPEAKER_FRONT_LEFT | SPEAKER_FRONT_RIGHT));
    if (result != S_OK && format.channels <= 2 && format.validBits == format.containerBits && legacyMask) {
        wave.Format.wFormatTag = format.encoding == SampleEncoding::floatingPoint ? WAVE_FORMAT_IEEE_FLOAT : WAVE_FORMAT_PCM;
        wave.Format.cbSize = 0;
        CoMemory<WAVEFORMATEX> legacyClosest;
        const HRESULT legacyResult = client->IsFormatSupported(exclusive ? AUDCLNT_SHAREMODE_EXCLUSIVE : AUDCLNT_SHAREMODE_SHARED,
            &wave.Format, exclusive ? nullptr : &legacyClosest.value);
        if (legacyResult == S_OK) result = legacyResult;
        else wave = makeFormat(format);
    }
    if (result == S_OK && accepted) *accepted = wave;
    WasapiFormatSupport support;
    support.exact = result == S_OK;
    support.nativeError = static_cast<std::uint32_t>(result);
    if (!support.exact && closest.value) {
        try { support.closestSharedFormat = parseFormat(closest.value); }
        catch (const AudioDeviceError&) {} // Encoded/unsupported closest matches remain explicitly unusable.
    }
    return support;
}
bool invalidated(HRESULT result) noexcept {
    return result == AUDCLNT_E_DEVICE_INVALIDATED || result == AUDCLNT_E_RESOURCES_INVALIDATED ||
           result == AUDCLNT_E_SERVICE_NOT_RUNNING;
}
REFERENCE_TIME duration(std::uint32_t frames, std::uint32_t rate) noexcept {
    return static_cast<REFERENCE_TIME>(std::llround(10000000. * frames / rate));
}
std::vector<std::uint32_t> channelMap(const std::vector<std::uint32_t>& selected, unsigned total) {
    auto result = selected;
    if (result.empty()) { result.resize(total); std::iota(result.begin(), result.end(), 0u); }
    if (result.size() > WasapiDevice::maximumChannels) throw AudioDeviceError("Too many active audio channels.", E_INVALIDARG);
    std::array<bool, WasapiDevice::maximumChannels> used{};
    for (const auto channel : result) {
        if (channel >= total || used[channel]) throw AudioDeviceError("Invalid or duplicate physical audio channel.", E_INVALIDARG);
        used[channel] = true;
    }
    return result;
}
} // namespace

std::vector<WasapiEndpoint> WasapiDevice::enumerate(bool includeInactive) {
    Apartment apartment;
    const auto devices = enumerator();
    std::array<std::array<std::wstring, 3>, 2> defaults;
    for (int direction = 0; direction < 2; ++direction) for (int role = 0; role < 3; ++role) {
        ComPtr<IMMDevice> endpoint;
        if (SUCCEEDED(devices->GetDefaultAudioEndpoint(direction ? eCapture : eRender, static_cast<ERole>(role), endpoint.GetAddressOf())))
            defaults[direction][role] = endpointID(endpoint.Get());
    }
    ComPtr<IMMDeviceCollection> collection;
    require(devices->EnumAudioEndpoints(eAll, includeInactive ? DEVICE_STATEMASK_ALL : DEVICE_STATE_ACTIVE,
                                       collection.GetAddressOf()), "Cannot list audio endpoints");
    UINT count = 0;
    require(collection->GetCount(&count), "Cannot count audio endpoints");
    std::vector<WasapiEndpoint> result;
    result.reserve(count);
    for (UINT index = 0; index < count; ++index) {
        ComPtr<IMMDevice> endpoint;
        if (FAILED(collection->Item(index, endpoint.GetAddressOf()))) continue;
        auto value = describe(endpoint.Get());
        const auto& roles = defaults[value.direction == Direction::capture ? 1 : 0];
        value.defaultConsole = value.id == roles[eConsole];
        value.defaultMultimedia = value.id == roles[eMultimedia];
        value.defaultCommunications = value.id == roles[eCommunications];
        result.push_back(std::move(value));
    }
    return result;
}
WasapiCapabilities WasapiDevice::inspect(const std::wstring& id) {
    Apartment apartment;
    const auto devices = enumerator();
    ComPtr<IMMDevice> endpoint;
    require(devices->GetDevice(id.c_str(), endpoint.GetAddressOf()), "Cannot inspect the selected audio endpoint");
    auto client = activate(endpoint.Get());
    WasapiCapabilities result;
    result.endpoint = describe(endpoint.Get());
    CoMemory<WAVEFORMATEX> mix;
    require(client->GetMixFormat(&mix.value), "Cannot inspect the endpoint mix format");
    result.mixFormat = parseFormat(mix.value);
    REFERENCE_TIME normal = 0, minimum = 0;
    require(client->GetDevicePeriod(&normal, &minimum), "Cannot inspect the endpoint period");
    result.defaultPeriod100ns = static_cast<std::uint64_t>(normal);
    result.minimumPeriod100ns = static_cast<std::uint64_t>(minimum);
    ComPtr<IAudioClient3> modern;
    if (SUCCEEDED(client.As(&modern)))
        result.sharedLowLatency = SUCCEEDED(modern->GetSharedModeEnginePeriod(mix.value, &result.defaultSharedPeriodFrames,
            &result.fundamentalSharedPeriodFrames, &result.minimumSharedPeriodFrames, &result.maximumSharedPeriodFrames));
    return result;
}
WasapiFormatSupport WasapiDevice::probeFormat(const std::wstring& id, DeviceMode mode, const SampleFormat& format) {
    if (mode == DeviceMode::asio) throw AudioDeviceError("ASIO is not a WASAPI mode.", E_INVALIDARG);
    Apartment apartment;
    const auto devices = enumerator();
    ComPtr<IMMDevice> endpoint;
    require(devices->GetDevice(id.c_str(), endpoint.GetAddressOf()), "Cannot query the selected audio endpoint");
    auto client = activate(endpoint.Get());
    return probe(client.Get(), mode, format);
}

struct WasapiDevice::Impl {
    struct NotificationSignals {
        EventHandle event;
        std::atomic<std::uint32_t> pending{0}, reported{0};
    };
    std::mutex control;
    EventHandle exitEvent{true}, finishedEvent{true}, commandEvent, doneEvent, audioEvent;
    // Notification objects retain their own signal storage. A callback never
    // dereferences Impl, even if COM finishes dispatching during shutdown.
    const std::shared_ptr<NotificationSignals> signals = std::make_shared<NotificationSignals>();
    std::thread worker;
    StreamRequest request;
    StreamInfo negotiated;
    std::atomic<DeviceState> state{DeviceState::closed};
    std::atomic<std::uint32_t> nativeError{0}, command{0};
    std::atomic<std::uint64_t> callbackCount{0}, frameCount{0}, discontinuityCount{0};
    std::atomic<bool> mmcssActive{false};
    ProcessCallback callback = nullptr;
    void* user = nullptr;
    std::string preparationError;
    enum Command : std::uint32_t { none, begin, end };

    class Notifications final : public IMMNotificationClient {
        std::atomic<ULONG> references{1};
        const std::shared_ptr<NotificationSignals> signals;
        std::atomic<bool> attached{true};
        std::atomic<std::uint32_t> publishers{0};
        const std::wstring id;
        EDataFlow flow;
        bool selectedDefault;
        bool selected(LPCWSTR value) const noexcept { return value && std::wcscmp(value, id.c_str()) == 0; }
        HRESULT publish(std::uint32_t flags) noexcept {
            publishers.fetch_add(1, std::memory_order_seq_cst);
            if (attached.load(std::memory_order_seq_cst)) {
                signals->reported.fetch_or(flags, std::memory_order_release);
                signals->pending.fetch_or(flags, std::memory_order_release);
                SetEvent(signals->event.value);
            }
            publishers.fetch_sub(1, std::memory_order_seq_cst);
            return S_OK;
        }
    public:
        Notifications(std::shared_ptr<NotificationSignals> value, std::wstring endpoint, EDataFlow direction, bool followsDefault)
            : signals(std::move(value)), id(std::move(endpoint)), flow(direction), selectedDefault(followsDefault) {}
        void detach() noexcept {
            attached.store(false, std::memory_order_seq_cst);
            // Only the stopped worker waits; notification callbacks never wait.
            while (publishers.load(std::memory_order_seq_cst)) Sleep(1);
        }
        ULONG STDMETHODCALLTYPE AddRef() override { return references.fetch_add(1, std::memory_order_relaxed) + 1; }
        ULONG STDMETHODCALLTYPE Release() override {
            const ULONG remaining = references.fetch_sub(1, std::memory_order_acq_rel) - 1;
            if (!remaining) delete this;
            return remaining;
        }
        HRESULT STDMETHODCALLTYPE QueryInterface(REFIID iid, void** value) override {
            if (!value) return E_POINTER;
            *value = nullptr;
            if (iid != __uuidof(IUnknown) && iid != __uuidof(IMMNotificationClient)) return E_NOINTERFACE;
            *value = static_cast<IMMNotificationClient*>(this); AddRef(); return S_OK;
        }
        HRESULT STDMETHODCALLTYPE OnDeviceAdded(LPCWSTR) override { return publish(devicesChanged); }
        HRESULT STDMETHODCALLTYPE OnDeviceRemoved(LPCWSTR value) override {
            return publish(devicesChanged | (selected(value) ? endpointInvalidated : 0));
        }
        HRESULT STDMETHODCALLTYPE OnDeviceStateChanged(LPCWSTR value, DWORD flags) override {
            return publish(devicesChanged | (selected(value) && !(flags & DEVICE_STATE_ACTIVE) ? endpointInvalidated : 0));
        }
        HRESULT STDMETHODCALLTYPE OnDefaultDeviceChanged(EDataFlow direction, ERole role, LPCWSTR) override {
            return publish(devicesChanged | (selectedDefault && direction == flow && role == eMultimedia ? defaultDeviceChanged : 0));
        }
        HRESULT STDMETHODCALLTYPE OnPropertyValueChanged(LPCWSTR value, const PROPERTYKEY key) override {
            return publish(devicesChanged | (selected(value) && IsEqualPropertyKey(key, PKEY_AudioEngine_DeviceFormat) ? formatChanged : 0));
        }
    };
    struct Runtime {
        Impl& owner;
        ComPtr<IMMDeviceEnumerator> devices;
        ComPtr<IMMDevice> endpoint;
        ComPtr<IAudioClient> client;
        ComPtr<IAudioRenderClient> render;
        ComPtr<IAudioCaptureClient> capture;
        ComPtr<Notifications> notifications;
        bool registered = false, running = false, usable = true;
        HANDLE mmcss = nullptr;
        std::optional<detail::PCMConversion> conversion;
        std::vector<float> planes;
        std::array<float*, maximumChannels> pointers{};
        std::array<const float*, maximumChannels> inputs{};
        std::vector<std::uint32_t> channels;
        std::uint32_t capacity = 0;
        std::uint32_t captureBufferMisses = 0;
        DWORD eventTimeoutMilliseconds = 2000;
        std::uint64_t submitted = 0;
        LARGE_INTEGER qpcFrequency{};
        explicit Runtime(Impl& value) : owner(value) {}
        void leaveRealtime() noexcept {
            if (mmcss) { AvRevertMmThreadCharacteristics(mmcss); mmcss = nullptr; }
            owner.mmcssActive.store(false, std::memory_order_release);
        }
        void halt() noexcept {
            leaveRealtime();
            if (running && client) client->Stop();
            running = false;
        }
        ~Runtime() {
            halt();
            // Notification callbacks only publish flags. Unregister and final
            // COM releases happen here, off the processing path on this MTA.
            if (notifications) notifications->detach();
            if (registered) devices->UnregisterEndpointNotificationCallback(notifications.Get());
        }
        void prepare() {
            const auto& request = owner.request;
            devices = enumerator();
            const EDataFlow flow = request.mode == DeviceMode::loopback || request.direction == Direction::render ? eRender : eCapture;
            if (request.endpointId.empty())
                require(devices->GetDefaultAudioEndpoint(flow, eMultimedia, endpoint.GetAddressOf()), "Cannot open the default audio endpoint");
            else require(devices->GetDevice(request.endpointId.c_str(), endpoint.GetAddressOf()), "Cannot open the selected audio endpoint");
            const auto endpointDescription = describe(endpoint.Get());
            if ((endpointDescription.direction == Direction::render) != (flow == eRender))
                throw AudioDeviceError("The selected endpoint has the wrong input/output direction.", AUDCLNT_E_WRONG_ENDPOINT_TYPE);
            client = activate(endpoint.Get());
            CoMemory<WAVEFORMATEX> mix;
            require(client->GetMixFormat(&mix.value), "Cannot read the endpoint mix format");
            auto format = request.format ? *request.format : parseFormat(mix.value);
            if (request.sampleRate) format.sampleRate = request.sampleRate;
            if (!format.sampleRate) format.sampleRate = mix.value->nSamplesPerSec;
            WAVEFORMATEXTENSIBLE wave{};
            const auto support = probe(client.Get(), request.mode, format, &wave);
            if (!support.exact)
                throw AudioDeviceError("The endpoint does not support the exact requested PCM format; choose an explicitly supported format.",
                    support.nativeError == S_FALSE ? static_cast<std::uint32_t>(AUDCLNT_E_UNSUPPORTED_FORMAT) : support.nativeError);
            REFERENCE_TIME defaultPeriod = 0, minimumPeriod = 0;
            require(client->GetDevicePeriod(&defaultPeriod, &minimumPeriod), "Cannot read the endpoint period");
            DWORD flags = AUDCLNT_STREAMFLAGS_EVENTCALLBACK;
            if (request.mode == DeviceMode::loopback) flags |= AUDCLNT_STREAMFLAGS_LOOPBACK;
            std::uint32_t periodFrames = static_cast<std::uint32_t>(std::llround(defaultPeriod * format.sampleRate / 10000000.));
            if (request.mode == DeviceMode::sharedLowLatency) {
                ComPtr<IAudioClient3> modern;
                require(client.As(&modern), "This endpoint does not expose low-latency shared WASAPI");
                UINT32 normal = 0, fundamental = 0, minimum = 0, maximum = 0;
                require(modern->GetSharedModeEnginePeriod(&wave.Format, &normal, &fundamental, &minimum, &maximum),
                        "Cannot query the shared engine period");
                periodFrames = request.requestedBufferFrames ? request.requestedBufferFrames : minimum;
                if (!fundamental || periodFrames < minimum || periodFrames > maximum || periodFrames % fundamental)
                    throw AudioDeviceError("The requested shared period is outside the endpoint's supported multiples.", E_INVALIDARG);
                require(modern->InitializeSharedAudioStream(flags, periodFrames, &wave.Format, nullptr),
                        "Cannot initialize low-latency shared WASAPI");
            } else {
                const bool exclusive = request.mode == DeviceMode::exclusive;
                REFERENCE_TIME bufferTime = request.requestedBufferFrames ? duration(request.requestedBufferFrames, format.sampleRate) :
                    exclusive ? defaultPeriod : 0;
                HRESULT result = client->Initialize(exclusive ? AUDCLNT_SHAREMODE_EXCLUSIVE : AUDCLNT_SHAREMODE_SHARED,
                    flags, bufferTime, exclusive ? bufferTime : 0, &wave.Format, nullptr);
                if (exclusive && result == AUDCLNT_E_BUFFER_SIZE_NOT_ALIGNED) {
                    UINT32 alignedFrames = 0;
                    require(client->GetBufferSize(&alignedFrames), "Cannot read the exclusive buffer alignment");
                    if (!alignedFrames || alignedFrames > maximumBufferFrames)
                        throw AudioDeviceError("The aligned exclusive buffer exceeds the configured limit.", AUDCLNT_E_BUFFER_SIZE_ERROR);
                    bufferTime = duration(alignedFrames, format.sampleRate);
                    client.Reset();
                    client = activate(endpoint.Get());
                    result = client->Initialize(AUDCLNT_SHAREMODE_EXCLUSIVE, flags, bufferTime, bufferTime, &wave.Format, nullptr);
                }
                require(result, "Cannot initialize the requested WASAPI mode");
                if (exclusive) periodFrames = static_cast<std::uint32_t>(std::llround(bufferTime * format.sampleRate / 10000000.));
            }
            require(client->GetBufferSize(&capacity), "Cannot read the negotiated WASAPI buffer size");
            if (!capacity || capacity > maximumBufferFrames)
                throw AudioDeviceError("The negotiated audio buffer exceeds the configured limit.", AUDCLNT_E_BUFFER_SIZE_ERROR);
            require(client->SetEventHandle(owner.audioEvent.value), "Cannot configure WASAPI event notification");
            if (request.direction == Direction::render)
                require(client->GetService(IID_PPV_ARGS(render.GetAddressOf())), "Cannot access the render endpoint buffer");
            else require(client->GetService(IID_PPV_ARGS(capture.GetAddressOf())), "Cannot access the capture endpoint buffer");
            channels = channelMap(request.direction == Direction::render ? request.outputChannelIndices : request.inputChannelIndices, format.channels);
            planes.assign(std::size_t(capacity) * channels.size(), 0.f);
            for (std::size_t channel = 0; channel < channels.size(); ++channel)
                inputs[channel] = pointers[channel] = planes.data() + channel * capacity;
            conversion.emplace(format);
            QueryPerformanceFrequency(&qpcFrequency);
            auto& info = owner.negotiated;
            info.endpointId = endpointDescription.id;
            info.mode = request.mode;
            info.sampleRate = format.sampleRate;
            info.bufferFrames = info.maximumCallbackFrames = capacity;
            info.periodFrames = periodFrames;
            eventTimeoutMilliseconds = static_cast<DWORD>(std::max(2000.,
                std::ceil(4000. * std::max(capacity, periodFrames) / format.sampleRate)));
            info.deviceFormat = format;
            if (request.direction == Direction::render) {
                info.outputChannels = static_cast<std::uint32_t>(channels.size()); info.outputChannelIndices = channels;
            } else { info.inputChannels = static_cast<std::uint32_t>(channels.size()); info.inputChannelIndices = channels; }
            REFERENCE_TIME latency = 0;
            if (SUCCEEDED(client->GetStreamLatency(&latency)) && latency > 0) info.latency100ns = static_cast<std::uint64_t>(latency);
            notifications.Attach(new Notifications(owner.signals, info.endpointId, flow, request.endpointId.empty()));
            require(devices->RegisterEndpointNotificationCallback(notifications.Get()), "Cannot register audio device notifications");
            registered = true;
        }
        void failure(HRESULT result) noexcept {
            usable = false;
            halt();
            owner.nativeError.store(static_cast<std::uint32_t>(result), std::memory_order_relaxed);
            owner.state.store(invalidated(result) ? DeviceState::invalidated : DeviceState::failed, std::memory_order_release);
            if (invalidated(result)) owner.signals->reported.fetch_or(endpointInvalidated, std::memory_order_release);
        }
        HRESULT renderBlock(bool prime = false) noexcept {
            UINT32 available = capacity;
            UINT32 padding = 0;
            if (owner.request.mode != DeviceMode::exclusive && !prime) {
                const HRESULT result = client->GetCurrentPadding(&padding);
                if (FAILED(result)) return result;
                if (padding > capacity) return AUDCLNT_E_BUFFER_SIZE_ERROR;
                available -= padding;
            }
            if (!available) return S_OK;
            BYTE* data = nullptr;
            HRESULT result = render->GetBuffer(available, &data);
            if (FAILED(result)) return result;
            if (!data) { render->ReleaseBuffer(available, AUDCLNT_BUFFERFLAGS_SILENT); return E_POINTER; }
            for (std::size_t channel = 0; channel < channels.size(); ++channel) std::fill_n(pointers[channel], available, 0.f);
            AudioBlock block;
            block.outputs = pointers.data(); block.outputChannels = static_cast<std::uint32_t>(channels.size());
            block.frames = available; block.sampleRate = owner.negotiated.sampleRate; block.framePosition = submitted;
            LARGE_INTEGER now{};
            if (QueryPerformanceCounter(&now) && qpcFrequency.QuadPart > 0) {
                block.qpcTime100ns = static_cast<std::uint64_t>(double(now.QuadPart) * 10000000. / qpcFrequency.QuadPart +
                    10000000. * padding / block.sampleRate);
                block.flags |= timestampValid | timestampEstimated;
            }
            if (prime) block.flags |= priming;
            owner.callback(owner.user, block);
            conversion->encode(pointers.data(), data, channels.data(), block.outputChannels, available);
            result = render->ReleaseBuffer(available, 0);
            if (SUCCEEDED(result)) {
                submitted += available;
                owner.callbackCount.fetch_add(1, std::memory_order_relaxed);
                owner.frameCount.fetch_add(available, std::memory_order_relaxed);
            }
            return result;
        }
        HRESULT captureBlocks() noexcept {
            const bool exclusive = owner.request.mode == DeviceMode::exclusive;
            std::uint32_t processed = 0;
            for (std::uint32_t packet = 0; packet < capacity && processed < capacity; ++packet) {
                UINT32 next = 0;
                HRESULT result = S_OK;
                // GetNextPacketSize is supported only in shared mode. An
                // exclusive event represents one complete endpoint buffer.
                if (!exclusive) {
                    result = capture->GetNextPacketSize(&next);
                    if (FAILED(result) || !next) return result;
                    if (next > capacity) return AUDCLNT_E_BUFFER_SIZE_ERROR;
                    if (next > capacity - processed) break;
                }
                BYTE* data = nullptr;
                UINT32 frames = 0; DWORD flags = 0;
                UINT64 position = 0, qpc = 0;
                result = capture->GetBuffer(&data, &frames, &flags, &position, &qpc);
                if (result == AUDCLNT_S_BUFFER_EMPTY) return S_OK;
                // Exclusive capture may report a temporarily missing packet.
                // Microsoft requires waiting for the next processing pass;
                // repeated misses make the stream explicitly unusable.
                if (exclusive && result == AUDCLNT_E_BUFFER_ERROR) {
                    owner.discontinuityCount.fetch_add(1, std::memory_order_relaxed);
                    return ++captureBufferMisses < 8 ? S_OK : result;
                }
                if (FAILED(result)) return result;
                if (!frames || frames > capacity - processed) {
                    capture->ReleaseBuffer(frames); return AUDCLNT_E_BUFFER_SIZE_ERROR;
                }
                if (!data && !(flags & AUDCLNT_BUFFERFLAGS_SILENT)) {
                    capture->ReleaseBuffer(frames); return E_POINTER;
                }
                conversion->decode(data, pointers.data(), channels.data(), static_cast<std::uint32_t>(channels.size()), frames,
                                   (flags & AUDCLNT_BUFFERFLAGS_SILENT) != 0);
                // Release the OS packet before user DSP; the planar copy is
                // preallocated and remains valid until this callback returns.
                result = capture->ReleaseBuffer(frames);
                if (FAILED(result)) return result;
                AudioBlock block;
                block.inputs = inputs.data(); block.inputChannels = static_cast<std::uint32_t>(channels.size());
                block.frames = frames; block.sampleRate = owner.negotiated.sampleRate;
                block.framePosition = position; block.qpcTime100ns = qpc;
                if (captureBufferMisses) block.flags |= discontinuity;
                captureBufferMisses = 0;
                if (flags & AUDCLNT_BUFFERFLAGS_SILENT) block.flags |= silentInput;
                if (!(flags & AUDCLNT_BUFFERFLAGS_TIMESTAMP_ERROR)) block.flags |= timestampValid;
                if (flags & AUDCLNT_BUFFERFLAGS_DATA_DISCONTINUITY) {
                    block.flags |= discontinuity; owner.discontinuityCount.fetch_add(1, std::memory_order_relaxed);
                }
                owner.callback(owner.user, block);
                owner.callbackCount.fetch_add(1, std::memory_order_relaxed);
                owner.frameCount.fetch_add(frames, std::memory_order_relaxed);
                processed += frames;
                if (exclusive) return S_OK;
            }
            // A single wake never drains an unbounded stream. Yield through the
            // wait set so stop/device changes always win over additional data.
            SetEvent(owner.audioEvent.value);
            return S_OK;
        }
        HRESULT beginStream() noexcept {
            if (!usable || (owner.signals->pending.load(std::memory_order_acquire) & (endpointInvalidated | formatChanged)))
                return AUDCLNT_E_DEVICE_INVALIDATED;
            HRESULT result = client->Reset();
            if (FAILED(result)) return result;
            ResetEvent(owner.audioEvent.value);
            submitted = 0;
            captureBufferMisses = 0;
            // stop() reverts the previous task registration. Each restart must
            // register afresh, without reusing its now-invalid task identifier.
            DWORD mmcssTask = 0;
            mmcss = AvSetMmThreadCharacteristicsW(L"Pro Audio", &mmcssTask);
            if (!mmcss) { const DWORD error = GetLastError(); return error ? HRESULT_FROM_WIN32(error) : E_FAIL; }
            if (!AvSetMmThreadPriority(mmcss, AVRT_PRIORITY_CRITICAL)) {
                const DWORD error = GetLastError(); result = error ? HRESULT_FROM_WIN32(error) : E_FAIL;
                leaveRealtime(); return result;
            }
            owner.mmcssActive.store(true, std::memory_order_release);
            if (render) result = renderBlock(true);
            if (SUCCEEDED(result)) result = client->Start();
            if (FAILED(result)) { leaveRealtime(); client->Reset(); return result; }
            running = true;
            return S_OK;
        }
    };
    void run() noexcept {
        struct Finished {
            HANDLE event;
            ~Finished() { SetEvent(event); }
        } finished{finishedEvent.value};
        try {
            Apartment apartment(true);
            SetThreadDescription(GetCurrentThread(), L"CatLive native WASAPI");
            Runtime runtime(*this);
            runtime.prepare();
            state.store(DeviceState::prepared, std::memory_order_release);
            SetEvent(doneEvent.value);
            const HANDLE events[]{exitEvent.value, commandEvent.value, signals->event.value, audioEvent.value};
            for (;;) {
                const DWORD result = WaitForMultipleObjects(4, events, FALSE,
                    runtime.running ? runtime.eventTimeoutMilliseconds : INFINITE);
                if (result == WAIT_OBJECT_0) break;
                if (result == WAIT_OBJECT_0 + 1) {
                    const auto action = command.exchange(none, std::memory_order_acq_rel);
                    if (action == begin) {
                        const HRESULT started = runtime.beginStream();
                        if (FAILED(started)) runtime.failure(started);
                        else { nativeError.store(0, std::memory_order_relaxed); state.store(DeviceState::running, std::memory_order_release); }
                    } else if (action == end) {
                        runtime.halt();
                        const auto previous = state.load(std::memory_order_acquire);
                        if (previous != DeviceState::failed && previous != DeviceState::invalidated) {
                            const HRESULT reset = runtime.client->Reset();
                            if (FAILED(reset)) runtime.failure(reset);
                            else state.store(DeviceState::stopped, std::memory_order_release);
                        }
                    }
                    SetEvent(doneEvent.value);
                } else if (result == WAIT_OBJECT_0 + 2) {
                    const auto changes = signals->pending.exchange(0, std::memory_order_acq_rel);
                    if (changes & (endpointInvalidated | formatChanged)) runtime.failure(AUDCLNT_E_DEVICE_INVALIDATED);
                } else if (result == WAIT_OBJECT_0 + 3) {
                    if (!runtime.running) continue;
                    const HRESULT processed = runtime.render ? runtime.renderBlock() : runtime.captureBlocks();
                    if (FAILED(processed)) runtime.failure(processed);
                } else if (result == WAIT_TIMEOUT) {
                    // Silent loopback/capture can legitimately have no packet.
                    if (runtime.render) runtime.failure(HRESULT_FROM_WIN32(ERROR_TIMEOUT));
                } else {
                    const DWORD error = GetLastError();
                    runtime.failure(error ? HRESULT_FROM_WIN32(error) : E_FAIL);
                    break;
                }
            }
        } catch (const AudioDeviceError& error) {
            preparationError = error.what(); nativeError.store(error.nativeCode(), std::memory_order_relaxed);
            state.store(DeviceState::failed, std::memory_order_release); SetEvent(doneEvent.value);
        } catch (const std::exception& error) {
            preparationError = error.what(); nativeError.store(E_FAIL, std::memory_order_relaxed);
            state.store(DeviceState::failed, std::memory_order_release); SetEvent(doneEvent.value);
        } catch (...) {
            nativeError.store(E_FAIL, std::memory_order_relaxed);
            state.store(DeviceState::failed, std::memory_order_release); SetEvent(doneEvent.value);
        }
    }
    void send(Command value) noexcept {
        ResetEvent(doneEvent.value);
        command.store(value, std::memory_order_release);
        SetEvent(commandEvent.value);
        // All command waits are control-thread waits. Processing holds no mutex.
        const HANDLE completion[]{doneEvent.value, finishedEvent.value};
        WaitForMultipleObjects(2, completion, FALSE, INFINITE);
    }
    void closeLocked() noexcept {
        if (worker.joinable()) { SetEvent(exitEvent.value); worker.join(); }
        callback = nullptr; user = nullptr;
        negotiated = {}; request = {};
        state.store(DeviceState::closed, std::memory_order_release);
    }
};

WasapiDevice::WasapiDevice() : impl(std::make_unique<Impl>()) {}
WasapiDevice::~WasapiDevice() { close(); }
void WasapiDevice::open(const StreamRequest& request) {
    if (request.direction == Direction::duplex || request.mode == DeviceMode::asio ||
        (request.mode == DeviceMode::loopback && request.direction != Direction::capture) ||
        (request.direction == Direction::render && !request.inputChannelIndices.empty()) ||
        (request.direction == Direction::capture && !request.outputChannelIndices.empty()) ||
        request.requestedBufferFrames > maximumBufferFrames)
        throw AudioDeviceError("Unsupported WASAPI direction, channel selection, mode or buffer size.", E_INVALIDARG);
    std::lock_guard<std::mutex> lock(impl->control);
    impl->closeLocked();
    impl->request = request;
    impl->preparationError.clear();
    impl->nativeError.store(0); impl->callbackCount.store(0); impl->frameCount.store(0); impl->discontinuityCount.store(0);
    impl->command.store(Impl::none); impl->signals->pending.store(0); impl->signals->reported.store(0);
    ResetEvent(impl->exitEvent.value); ResetEvent(impl->commandEvent.value); ResetEvent(impl->doneEvent.value);
    ResetEvent(impl->finishedEvent.value); ResetEvent(impl->signals->event.value); ResetEvent(impl->audioEvent.value);
    impl->worker = std::thread([owner = impl.get()] { owner->run(); });
    WaitForSingleObject(impl->doneEvent.value, INFINITE);
    if (impl->state.load(std::memory_order_acquire) != DeviceState::prepared) {
        const auto code = impl->nativeError.load();
        const auto message = impl->preparationError.empty() ? failureText("Cannot prepare WASAPI", static_cast<HRESULT>(code)) : impl->preparationError;
        impl->closeLocked();
        throw AudioDeviceError(message, code);
    }
}
void WasapiDevice::start(ProcessCallback callback, void* user) {
    if (!callback) throw AudioDeviceError("An audio callback is required.", E_POINTER);
    std::lock_guard<std::mutex> lock(impl->control);
    const auto state = impl->state.load(std::memory_order_acquire);
    if (state != DeviceState::prepared && state != DeviceState::stopped)
        throw AudioDeviceError("Open or reopen the endpoint before starting WASAPI.", AUDCLNT_E_NOT_INITIALIZED);
    impl->callback = callback; impl->user = user;
    impl->state.store(DeviceState::starting, std::memory_order_release);
    impl->send(Impl::begin);
    if (impl->state.load(std::memory_order_acquire) != DeviceState::running) {
        const auto code = impl->nativeError.load();
        throw AudioDeviceError(failureText("Cannot start WASAPI", static_cast<HRESULT>(code)), code);
    }
}
void WasapiDevice::stop() noexcept {
    std::lock_guard<std::mutex> lock(impl->control);
    if (impl->worker.joinable()) impl->send(Impl::end);
}
void WasapiDevice::close() noexcept {
    if (!impl) return;
    std::lock_guard<std::mutex> lock(impl->control);
    impl->closeLocked();
}
const StreamInfo& WasapiDevice::info() const noexcept { return impl->negotiated; }
DeviceStatus WasapiDevice::status() const noexcept {
    DeviceStatus result;
    result.state = impl->state.load(std::memory_order_acquire);
    result.nativeError = impl->nativeError.load(std::memory_order_relaxed);
    result.callbacks = impl->callbackCount.load(std::memory_order_relaxed);
    result.frames = impl->frameCount.load(std::memory_order_relaxed);
    result.discontinuities = impl->discontinuityCount.load(std::memory_order_relaxed);
    result.mmcssActive = impl->mmcssActive.load(std::memory_order_acquire);
    return result;
}
std::uint32_t WasapiDevice::consumeDeviceChanges() noexcept { return impl->signals->reported.exchange(0, std::memory_order_acq_rel); }
} // namespace catlive::native::audio
