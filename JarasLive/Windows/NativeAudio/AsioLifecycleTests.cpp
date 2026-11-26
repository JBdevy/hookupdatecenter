// This test compiles the production backend with a narrow, test-only operating
// system boundary: registry reads and driver creation use an in-memory fixture.
// COM initialization, thread identity, QPC, SDK types, and the complete backend
// lifecycle/callback implementation are unchanged. No registry is written, no
// driver DLL is loaded, and no physical audio device is opened.
#ifndef NOMINMAX
#define NOMINMAX
#endif
#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#include <windows.h>
#include <objbase.h>
#include <algorithm>
#include <array>
#include <atomic>
#include <cassert>
#include <chrono>
#include <cmath>
#include <cstdlib>
#include <cstring>
#include <cwchar>
#include <iostream>
#include <limits>
#include <new>
#include <string>
#include <thread>
#include <vector>

namespace asio_tests {
LONG closeKey(HKEY);
LONG queryValue(HKEY, const wchar_t*, DWORD*, DWORD*, BYTE*, DWORD*);
LONG openKey(HKEY, const wchar_t*, DWORD, REGSAM, HKEY*);
LONG enumKey(HKEY, DWORD, wchar_t*, DWORD*, DWORD*, wchar_t*, DWORD*, void*);
HRESULT createDriver(const CLSID&, IUnknown*, DWORD, const GUID&, void**);
}
// Remapping is confined to this test translation unit, after Windows headers.
// The production target never sees these definitions or the fixture below.
#define RegCloseKey asio_tests::closeKey
#define RegQueryValueExW asio_tests::queryValue
#define RegOpenKeyExW asio_tests::openKey
#define RegEnumKeyExW asio_tests::enumKey
#define CoCreateInstance asio_tests::createDriver
#include "AsioDevice.cpp"
#undef RegCloseKey
#undef RegQueryValueExW
#undef RegOpenKeyExW
#undef RegEnumKeyExW
#undef CoCreateInstance

namespace asio_tests {
using namespace catlive::native::audio;
constexpr const wchar_t* identifier = L"{00112233-4455-6677-8899-AABBCCDDEEFF}";
thread_local bool watchAllocations = false;
std::atomic<unsigned> allocations{0};
void* allocate(std::size_t size) {
    if (watchAllocations) allocations.fetch_add(1, std::memory_order_relaxed);
    if (void* result = std::malloc(size ? size : 1)) return result;
    throw std::bad_alloc();
}
struct Config {
    long inputs = 4, outputs = 6, minimum = 32, maximum = 1024, preferred = 64, granularity = -1;
    ASIOError startResult = ASE_OK, createResult = ASE_OK;
    ASIOSampleType inputType = ASIOSTFloat32LSB, outputType = ASIOSTInt24LSB;
    bool initOK = true, nullBuffer = false, callbackDuringStart = false;
};
struct Statistics {
    std::atomic<unsigned> created{0}, released{0}, starts{0}, stops{0}, creates{0}, disposes{0}, panels{0}, outputReady{0};
};
struct MockDriver;
struct Fixture {
    Config config;
    Statistics stats;
    MockDriver* driver = nullptr;
    bool registryMissing = false;
    unsigned registryViews = 0;
};
Fixture* fixture = nullptr;
constexpr std::uintptr_t rootKey = 0x100, driverKey = 0x101;
LONG closeKey(HKEY) { return ERROR_SUCCESS; }
LONG openKey(HKEY parent, const wchar_t* name, DWORD, REGSAM access, HKEY* result) {
    assert(fixture);
    if (parent == HKEY_LOCAL_MACHINE) {
        assert(std::wcscmp(name, L"SOFTWARE\\ASIO") == 0);
        fixture->registryViews |= access & (KEY_WOW64_32KEY | KEY_WOW64_64KEY);
        if (fixture->registryMissing) return ERROR_FILE_NOT_FOUND;
        *result = reinterpret_cast<HKEY>(rootKey); return ERROR_SUCCESS;
    }
    assert(reinterpret_cast<std::uintptr_t>(parent) == rootKey);
    if (std::wcscmp(name, L"Test ASIO") != 0) return ERROR_FILE_NOT_FOUND;
    *result = reinterpret_cast<HKEY>(driverKey); return ERROR_SUCCESS;
}
LONG queryValue(HKEY key, const wchar_t* name, DWORD*, DWORD* type, BYTE* bytes, DWORD* count) {
    assert(reinterpret_cast<std::uintptr_t>(key) == driverKey);
    const wchar_t* value = std::wcscmp(name, L"CLSID") == 0 ? identifier : L"In-memory ASIO fixture";
    const auto required = static_cast<DWORD>((std::wcslen(value) + 1) * sizeof(wchar_t));
    if (type) *type = REG_SZ;
    if (bytes && *count < required) { *count = required; return ERROR_MORE_DATA; }
    if (bytes) std::memcpy(bytes, value, required);
    *count = required; return ERROR_SUCCESS;
}
LONG enumKey(HKEY key, DWORD index, wchar_t* name, DWORD* count, DWORD*, wchar_t*, DWORD*, void*) {
    assert(reinterpret_cast<std::uintptr_t>(key) == rootKey);
    if (index) return ERROR_NO_MORE_ITEMS;
    assert(*count >= 10); std::wcscpy(name, L"Test ASIO"); *count = 9; return ERROR_SUCCESS;
}

struct MockDriver final : IASIO {
    Fixture& owner;
    Config config;
    ASIOCallbacks callbacks{};
    std::vector<ASIOBufferInfo> buffers;
    std::vector<std::vector<unsigned char>> storage;
    long frames = 0;
    double rate = 48000;
    ASIOError readyResult = ASE_OK;
    explicit MockDriver(Fixture& value) : owner(value), config(value.config) { ++owner.stats.created; }
    HRESULT STDMETHODCALLTYPE QueryInterface(const GUID&, void**) override { return E_NOINTERFACE; }
    ULONG STDMETHODCALLTYPE AddRef() override { return 1; }
    ULONG STDMETHODCALLTYPE Release() override { ++owner.stats.released; owner.driver = nullptr; delete this; return 0; }
    ASIOBool init(void*) override { return config.initOK ? ASIOTrue : ASIOFalse; }
    void getDriverName(char* value) override { std::strcpy(value, "Test driver"); }
    long getDriverVersion() override { return 1; }
    void getErrorMessage(char* value) override { std::strcpy(value, "Fixture initialization failure"); }
    ASIOError start() override {
        ++owner.stats.starts;
        if (config.callbackDuringStart) callbacks.bufferSwitch(0, ASIOTrue);
        return config.startResult;
    }
    ASIOError stop() override { ++owner.stats.stops; return ASE_OK; }
    ASIOError getChannels(long* inputs, long* outputs) override { *inputs = config.inputs; *outputs = config.outputs; return ASE_OK; }
    ASIOError getLatencies(long* input, long* output) override { *input = 64; *output = 128; return ASE_OK; }
    ASIOError getBufferSize(long* min, long* max, long* preferred, long* granularity) override {
        *min = config.minimum; *max = config.maximum; *preferred = config.preferred; *granularity = config.granularity; return ASE_OK;
    }
    ASIOError canSampleRate(double value) override { return value == 48000 || value == 44100 ? ASE_OK : ASE_InvalidParameter; }
    ASIOError getSampleRate(double* value) override { *value = rate; return ASE_OK; }
    ASIOError setSampleRate(double value) override { rate = value; return ASE_OK; }
    ASIOError getClockSources(ASIOClockSource*, long*) override { return ASE_NotPresent; }
    ASIOError setClockSource(long) override { return ASE_NotPresent; }
    ASIOError getSamplePosition(ASIOSamples*, ASIOTimeStamp*) override { assert(false && "The callback must not query the driver clock"); return ASE_InvalidMode; }
    ASIOError getChannelInfo(ASIOChannelInfo* value) override {
        value->type = value->isInput ? config.inputType : config.outputType;
        std::strcpy(value->name, "Test channel"); return ASE_OK;
    }
    ASIOError createBuffers(ASIOBufferInfo* values, long count, long size, ASIOCallbacks* call) override {
        ++owner.stats.creates;
        if (config.createResult != ASE_OK) return config.createResult;
        callbacks = *call; frames = size; storage.resize(static_cast<std::size_t>(count) * 2);
        for (long channel = 0; channel < count; ++channel) for (int index = 0; index < 2; ++index) {
            // Fixtures use IEEE float32 inputs and PCM24 outputs; conversion
            // tests independently cover all other supported wire encodings.
            auto& bytes = storage[static_cast<std::size_t>(channel) * 2 + index];
            bytes.resize(static_cast<std::size_t>(size) * (values[channel].isInput ? 4u : 3u), 0x7f);
            values[channel].buffers[index] = bytes.data();
        }
        buffers.assign(values, values + count);
        if (config.nullBuffer) values[0].buffers[0] = nullptr;
        return ASE_OK;
    }
    ASIOError disposeBuffers() override { ++owner.stats.disposes; buffers.clear(); storage.clear(); return ASE_OK; }
    ASIOError controlPanel() override { ++owner.stats.panels; return ASE_OK; }
    ASIOError future(long, void*) override { return ASE_NotPresent; }
    ASIOError outputReady() override { ++owner.stats.outputReady; return readyResult; }
    void fire(long index, ASIOTime* time = nullptr) {
        watchAllocations = true;
        if (time) assert(callbacks.bufferSwitchTimeInfo(time, index, ASIOTrue) == time);
        else callbacks.bufferSwitch(index, ASIOTrue);
        watchAllocations = false;
    }
    void fillInputs() {
        std::vector<float> samples(static_cast<std::size_t>(frames));
        for (const auto& buffer : buffers) if (buffer.isInput) {
            std::fill(samples.begin(), samples.end(), float(buffer.channelNum + 1) * .125f);
            for (void* destination : buffer.buffers) asio_detail::makeConverter({4,32,false,true}).encode(destination, samples.data(), samples.size());
        }
    }
    void assertOutputs(long index, const std::vector<std::uint32_t>& selected = {}) const {
        std::vector<float> samples(static_cast<std::size_t>(frames));
        for (const auto& buffer : buffers) if (!buffer.isInput) {
            const auto found = std::find(selected.begin(), selected.end(), static_cast<std::uint32_t>(buffer.channelNum));
            const float expected = found == selected.end() ? 0.f : .125f * float(std::distance(selected.begin(), found) + 1);
            asio_detail::makeConverter({3,24,false,false}).decode(samples.data(), buffer.buffers[index], samples.size());
            for (const float sample : samples) assert(sample == expected);
        }
    }
};
HRESULT createDriver(const CLSID& clsid, IUnknown* outer, DWORD context, const GUID& iid, void** value) {
    assert(fixture && !fixture->driver && !outer && context == CLSCTX_INPROC_SERVER && IsEqualCLSID(clsid, iid));
    fixture->driver = new MockDriver(*fixture); *value = fixture->driver; return S_OK;
}
struct Scope {
    Fixture value;
    Scope() { assert(!fixture); fixture = &value; }
    ~Scope() { assert(!value.driver); assert(value.stats.created == value.stats.released); fixture = nullptr; }
};
struct Capture {
    std::atomic<unsigned> calls{0};
    std::array<float, AsioDevice::maximumChannels> input{};
    AudioBlock last{};
    std::atomic<bool> hold{false}, entered{false}, release{false}, timedOut{false};
};
void process(void* user, const AudioBlock& block) noexcept {
    auto& capture = *static_cast<Capture*>(user);
    capture.last = block;
    assert(block.inputChannels <= capture.input.size() && block.frames > 0);
    for (std::uint32_t channel = 0; channel < block.inputChannels; ++channel) capture.input[channel] = block.inputs[channel][0];
    for (std::uint32_t channel = 0; channel < block.outputChannels; ++channel)
        for (std::uint32_t frame = 0; frame < block.frames; ++frame) {
            assert(block.outputs[channel][frame] == 0.f); block.outputs[channel][frame] = float(channel + 1) * .125f;
        }
    capture.calls.fetch_add(1, std::memory_order_release);
    capture.entered.store(true, std::memory_order_release);
    if (capture.hold.load(std::memory_order_acquire)) {
        // Deliberately hold this synthetic callback to exercise the lifecycle
        // drain. This test callback is not a production DSP example.
        const auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds(5);
        while (!capture.release.load(std::memory_order_acquire)) {
            if (std::chrono::steady_clock::now() >= deadline) { capture.timedOut = true; break; }
            std::this_thread::yield();
        }
    }
}
template<class Function> void rejects(Function&& function) {
    bool rejected = false; try { function(); } catch (const AudioDeviceError&) { rejected = true; }
    assert(rejected);
}
StreamRequest request() {
    StreamRequest result; result.endpointId = identifier; result.mode = DeviceMode::asio; result.direction = Direction::duplex; return result;
}
template<class Integer> void set64(Integer& destination, std::uint64_t value) {
#if NATIVE_INT64
    destination = value;
#else
    destination.hi = static_cast<unsigned long>(value >> 32); destination.lo = static_cast<unsigned long>(value & 0xffffffff);
#endif
}
void registryAndValidation() {
    Scope scope; auto& f = scope.value;
    assert(AsioDevice::available()); assert(AsioDevice::enumerate().size() == 1); assert(f.registryViews != 0);
    f.registryMissing = true; assert(AsioDevice::enumerate().empty()); f.registryMissing = false;
    AsioDevice device;
    for (const auto& indices : {std::vector<std::uint32_t>{4}, {1,1}}) {
        auto settings = request(); settings.inputChannelIndices = indices; rejects([&] { device.open(settings); }); assert(!f.driver);
    }
    auto settings = request(); settings.outputChannelIndices = {6}; rejects([&] { device.open(settings); }); assert(!f.driver);
    settings = request(); settings.direction = Direction::render; settings.inputChannelIndices = {0}; rejects([&] { device.open(settings); });
    for (const auto frames : {1u,48u,2048u}) { settings = request(); settings.requestedBufferFrames = frames; rejects([&] { device.open(settings); }); assert(!f.driver); }
    f.config.inputs = AsioDevice::maximumChannels + 1; rejects([&] { device.open(request()); }); f.config.inputs = 4;
    f.config.outputs = 0; rejects([&] { device.open(request()); }); f.config.outputs = 6;
    device.open(request()); assert(device.info().inputChannels == 4 && device.info().outputChannels == 6);
    AsioDevice second; rejects([&] { second.open(request()); });
    device.close(); second.open(request()); second.close(); assert(device.status().state == DeviceState::closed);
    settings = request(); settings.endpointId.clear(); rejects([&] { device.open(settings); });
    settings = request(); settings.format = SampleFormat{}; rejects([&] { device.open(settings); });
    settings = request(); settings.sampleRate = 32000; rejects([&] { device.open(settings); });
}
void routingAndRestart() {
    Scope scope; AsioDevice device; Capture capture;
    auto settings = request(); settings.inputChannelIndices = {3,1}; settings.outputChannelIndices = {5,2}; device.open(settings);
    auto& driver = *scope.value.driver; assert(driver.buffers.size() == 10); driver.fillInputs();
    assert(device.info().inputChannelIndices == settings.inputChannelIndices && device.info().outputChannelIndices == settings.outputChannelIndices);
    device.start(process, &capture); driver.assertOutputs(0); driver.assertOutputs(1);
    driver.fire(0); assert((capture.last.flags & (priming | silentInput)) == (priming | silentInput));
    assert(capture.input[0] == 0 && capture.input[1] == 0); driver.assertOutputs(0, settings.outputChannelIndices);
    driver.fire(1); assert(capture.input[0] == .5f && capture.input[1] == .25f); driver.assertOutputs(1, settings.outputChannelIndices);
    const auto calls = capture.calls.load(); device.stop(); assert(device.status().state == DeviceState::stopped);
    driver.fire(0); assert(capture.calls == calls); driver.assertOutputs(0);
    device.start(process, &capture); driver.assertOutputs(0); driver.assertOutputs(1);
    driver.fire(1); assert(capture.input[0] == 0 && capture.input[1] == 0 && (capture.last.flags & priming));
    device.stop(); device.close();
}
void directionAndPriming() {
    for (const auto direction : {Direction::render,Direction::capture,Direction::duplex}) {
        Scope scope; AsioDevice device; Capture capture; auto settings = request(); settings.direction = direction;
        scope.value.config.callbackDuringStart = true; device.open(settings); auto& driver = *scope.value.driver;
        device.start(process, &capture); assert(capture.calls == 1 && (capture.last.flags & priming));
        assert(capture.last.inputChannels == (direction == Direction::render ? 0u : 4u));
        assert(capture.last.outputChannels == (direction == Direction::capture ? 0u : 6u));
        const auto callbacks = driver.callbacks; device.close(); const auto calls = capture.calls.load();
        callbacks.bufferSwitch(0, ASIOTrue); assert(capture.calls == calls);
    }
    // Exercise the advertised capacity with distinct input data, so passing a
    // stereo-only or truncated channel list cannot accidentally satisfy tests.
    Scope scope; AsioDevice device; Capture capture;
    scope.value.config.inputs = scope.value.config.outputs = AsioDevice::maximumChannels;
    device.open(request()); auto& driver = *scope.value.driver; driver.fillInputs();
    assert(driver.buffers.size() == 2 * AsioDevice::maximumChannels);
    device.start(process, &capture); driver.fire(0); driver.fire(1);
    assert(capture.last.inputChannels == AsioDevice::maximumChannels && capture.last.outputChannels == AsioDevice::maximumChannels);
    assert(capture.input.back() == float(AsioDevice::maximumChannels) * .125f); device.close();
}
void timeInfoValidity() {
    Scope scope; AsioDevice device; Capture capture; device.open(request()); auto& driver = *scope.value.driver; device.start(process, &capture);
    ASIOTime time{}; set64(time.timeInfo.samplePosition, 900000); set64(time.timeInfo.systemTime, 800000);
    driver.fire(0, &time); assert(capture.last.framePosition == 0 && capture.last.deviceTimeNanoseconds == 0 && !(capture.last.flags & deviceTimestampValid));
    driver.fire(1, &time); assert(capture.last.framePosition == 64);
    time.timeInfo.flags = kSamplePositionValid | kSystemTimeValid;
    constexpr std::uint64_t position = (std::uint64_t(2) << 32) + 17, stamp = (std::uint64_t(3) << 32) + 23;
    set64(time.timeInfo.samplePosition, position); set64(time.timeInfo.systemTime, stamp); driver.fire(0, &time);
    assert(capture.last.framePosition == position && capture.last.deviceTimeNanoseconds == stamp);
    assert((capture.last.flags & (deviceTimestampValid | timestampValid | timestampEstimated)) == (deviceTimestampValid | timestampValid | timestampEstimated));
    assert(capture.last.qpcTime100ns > 0);
    time.timeInfo.flags = 0; driver.fire(1, &time); assert(capture.last.framePosition == position + 64 && capture.last.deviceTimeNanoseconds == 0);
    time.timeInfo.flags = kClockSourceChanged; time.timeInfo.sampleRate = 12345;
    const auto calls = capture.calls.load(); driver.fire(0, &time);
    assert(capture.calls == calls && device.status().state == DeviceState::invalidated);
    assert(device.pendingSampleRate() == 0 && (device.consumeDeviceChanges() & resetRequired));
    device.close(); device.open(request()); device.start(process, &capture);
    time.timeInfo.flags = kSampleRateChanged | kSampleRateValid; time.timeInfo.sampleRate = 44100;
    scope.value.driver->fire(0, &time); assert(device.pendingSampleRate() == 44100); device.close();
}
void deferredNotifications() {
    for (const long selector : {kAsioResetRequest,kAsioResyncRequest,kAsioLatenciesChanged}) {
        Scope scope; AsioDevice device; Capture capture; device.open(request()); auto& driver = *scope.value.driver; device.start(process, &capture);
        const auto stops = scope.value.stats.stops.load(), disposes = scope.value.stats.disposes.load();
        assert(driver.callbacks.asioMessage(kAsioSelectorSupported, selector, nullptr, nullptr) == 1);
        assert(driver.callbacks.asioMessage(selector, 0, nullptr, nullptr) == 1);
        assert(device.status().state == DeviceState::invalidated && (device.consumeDeviceChanges() & resetRequired));
        driver.fire(0); assert(capture.calls == 0); driver.assertOutputs(0);
        assert(scope.value.stats.stops == stops && scope.value.stats.disposes == disposes);
        rejects([&] { device.start(process, &capture); }); device.close();
    }
    Scope scope; AsioDevice device; Capture capture; device.open(request()); auto& driver = *scope.value.driver; device.start(process, &capture);
    assert(driver.callbacks.asioMessage(kAsioBufferSizeChange, 128, nullptr, nullptr) == 0);
    assert(driver.callbacks.asioMessage(kAsioSupportsTimeCode, 0, nullptr, nullptr) == 0);
    assert(driver.callbacks.asioMessage(kAsioOverload, 0, nullptr, nullptr) == 1);
    assert(device.status().state == DeviceState::running && device.status().discontinuities == 1);
    assert(device.consumeDeviceChanges() & driverOverload); driver.fire(0); assert(capture.last.flags & discontinuity);
    driver.fire(1); assert(!(capture.last.flags & discontinuity));
    driver.callbacks.sampleRateDidChange(44100); assert(device.pendingSampleRate() == 44100);
    assert((device.consumeDeviceChanges() & (resetRequired | sampleRateChanged | formatChanged)) == (resetRequired | sampleRateChanged | formatChanged));
    const auto calls = capture.calls.load(); driver.fire(0); assert(capture.calls == calls); driver.assertOutputs(0); device.close();
}
void failuresAndPanel() {
    Scope scope; AsioDevice device; Capture capture;
    scope.value.config.initOK = false; rejects([&] { device.open(request()); }); assert(!scope.value.driver); scope.value.config.initOK = true;
    scope.value.config.createResult = ASE_NoMemory; rejects([&] { device.open(request()); }); assert(!scope.value.driver); scope.value.config.createResult = ASE_OK;
    scope.value.config.nullBuffer = true; const auto disposes = scope.value.stats.disposes.load();
    rejects([&] { device.open(request()); }); assert(!scope.value.driver && scope.value.stats.disposes == disposes + 1); scope.value.config.nullBuffer = false;
    scope.value.config.inputType = ASIOSTDSDInt8LSB1; rejects([&] { device.open(request()); }); scope.value.config.inputType = ASIOSTFloat32LSB;
    scope.value.config.startResult = ASE_HWMalfunction; device.open(request()); rejects([&] { device.start(process, &capture); });
    assert(device.status().state == DeviceState::failed && device.status().nativeError == static_cast<std::uint32_t>(ASE_HWMalfunction)); device.close();
    scope.value.config.startResult = ASE_OK; device.open(request()); device.start(process, &capture);
    scope.value.driver->readyResult = ASE_HWMalfunction; scope.value.driver->fire(0);
    assert(device.status().state == DeviceState::invalidated && (device.consumeDeviceChanges() & resetRequired)); device.close();
    device.open(request()); device.start(process, &capture); device.controlPanel();
    assert(scope.value.stats.panels == 1 && device.status().state == DeviceState::invalidated); rejects([&] { device.start(process, &capture); }); device.close();
}
void callbackLifetime() {
    for (bool close : {false,true}) {
        Scope scope; AsioDevice device; Capture capture; device.open(request()); auto* driver = scope.value.driver;
        const auto callbacks = driver->callbacks; capture.hold = true; device.start(process, &capture);
        std::thread callback([&] { driver->fire(0); });
        const auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds(5);
        while (!capture.entered.load(std::memory_order_acquire) && std::chrono::steady_clock::now() < deadline) std::this_thread::yield();
        assert(capture.entered);
        std::atomic<bool> controlReturned{false}, returnedEarly{false};
        std::thread releaser([&] {
            const auto stopDeadline = std::chrono::steady_clock::now() + std::chrono::seconds(5);
            while (scope.value.stats.stops == 0 && std::chrono::steady_clock::now() < stopDeadline) std::this_thread::yield();
            assert(scope.value.stats.stops != 0);
            std::this_thread::sleep_for(std::chrono::milliseconds(20));
            returnedEarly = controlReturned.load(std::memory_order_acquire);
            capture.release.store(true, std::memory_order_release);
        });
        if (close) device.close(); else device.stop();
        controlReturned.store(true, std::memory_order_release); callback.join(); releaser.join();
        assert(!returnedEarly && !capture.timedOut);
        const auto calls = capture.calls.load(); callbacks.bufferSwitch(0, ASIOTrue); assert(capture.calls == calls);
        device.close();
    }
}
void invalidAndConcurrentCallbacks() {
    Scope scope; AsioDevice device; Capture capture; device.open(request()); device.start(process, &capture);
    scope.value.driver->fire(2);
    assert(capture.calls == 0 && device.status().state == DeviceState::invalidated && (device.consumeDeviceChanges() & resetRequired));
    device.close(); device.open(request()); auto* driver = scope.value.driver;
    capture.hold = true; device.start(process, &capture);
    std::thread first([&] { driver->fire(0); });
    const auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds(5);
    while (!capture.entered.load(std::memory_order_acquire) && std::chrono::steady_clock::now() < deadline) std::this_thread::yield();
    assert(capture.entered);
    // A faulty driver's overlapping callback must return without waiting for
    // the first callback or entering DSP against its shared planar buffers.
    driver->fire(1);
    assert(capture.calls == 1 && device.status().state == DeviceState::invalidated);
    assert((device.consumeDeviceChanges() & (driverOverload | resetRequired)) == (driverOverload | resetRequired));
    capture.release.store(true, std::memory_order_release); first.join(); assert(!capture.timedOut);
    driver->assertOutputs(0); device.close();
}
} // namespace asio_tests

void* operator new(std::size_t size) { return asio_tests::allocate(size); }
void* operator new[](std::size_t size) { return asio_tests::allocate(size); }
void operator delete(void* value) noexcept { std::free(value); }
void operator delete[](void* value) noexcept { std::free(value); }
void operator delete(void* value, std::size_t) noexcept { std::free(value); }
void operator delete[](void* value, std::size_t) noexcept { std::free(value); }
int main() {
    using namespace asio_tests;
    registryAndValidation(); routingAndRestart(); directionAndPriming(); timeInfoValidity(); deferredNotifications(); failuresAndPanel(); callbackLifetime(); invalidAndConcurrentCallbacks();
    assert(allocations.load() == 0);
    std::cout << "ASIO simulated-driver lifecycle passed: validation, channel routing, priming/restart, time-info validity, deferred notifications, failures, callback drain; no hardware exercised.\n";
}
