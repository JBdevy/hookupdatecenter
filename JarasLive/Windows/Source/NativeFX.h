#pragma once
#include "Common.h"
#include "Include/EQAnalysis.hpp"
#include "../../WindowsNative/Source/StemSeparator.h"
#include "../../WindowsNative/Source/VST3Host.h"
namespace catlive {
struct AutomationProgram;
class NativeFX {
public:
    struct PreparationCancelled : std::runtime_error {
        PreparationCancelled() : std::runtime_error("Abertura do projeto cancelada.") {}
    };
    // Project preparation can run off the UI thread, but VST3 controllers must
    // be constructed on it. The dispatcher completes the operation or throws.
    using Dispatcher = std::function<void(std::function<void()>)>;
    NativeFX();~NativeFX();
    void swap(NativeFX &) noexcept;
    // Call while the render owner is stopped/locked, immediately before replacement.
    void adoptDynamicsState(NativeFX &previous) noexcept;
    struct DynamicsPreview { std::array<double,8> trigger{}; std::array<double,7> gate{}; bool filterOutput=false; };
    static DynamicsPreview dynamicsPreview(const var &);
    void previewDynamics(const String &key, const DynamicsPreview &) noexcept;
    // Build on the control thread. Applying this bounded snapshot never allocates,
    // resets filter history, or loads assets under the device callback lock.
    struct ParameterPreview {
        enum Kind { none, equalizer, compressor, delay, reverb, limiter, pitch } kind = none;
        static constexpr size_t maximumEQStages = 160;
        std::array<std::array<float, 5>, maximumEQStages> eq{};
        unsigned eqCount = 0;
        double sampleRate = 48000;
        std::array<float, 16> values{};
        std::array<float, 5> highPass{}, lowPass{};
    };
    static ParameterPreview parameterPreview(const String &kind, const var &, double sampleRate);
    void previewParameters(const String &key, const ParameterPreview &) noexcept;
    void prepare(const var& settings,double sampleRate,const NativeFX *previous=nullptr,bool offline=false,bool prewarm=true,
                 const Dispatcher &pluginDispatcher = {}, const File &mediaDirectory = {});
    void process(AudioBuffer<float>&,int samples,double seconds=0,bool playing=true,const MidiBuffer *midi=nullptr,double stemSeconds=std::numeric_limits<double>::quiet_NaN());
    bool hasExternal() const;
    bool empty() const noexcept { return effects.empty(); }
    std::shared_ptr<analysis::Capture> eqAnalysis(const String &key) const;
    void applyAutomation(const AutomationProgram &, double time);
    unsigned latencyFrames() const;
    // Control-thread preview: allocate compensation before admitting ready DSP.
    unsigned readyLatencyFrames(bool releaseRemoved) const;
    void collectReadyStemActivations(std::vector<std::shared_ptr<native::stem::Processor>> &) const;
    void activateStemLatency(bool force=false);
    bool pendingStemChange()const;
    void holdRemovedStems(const NativeFX &);
    void releaseRemovedStems();
    void resetStems();
    void shareStems(const NativeFX &);
    bool hasActiveStem()const;
    native::stem::Status stemStatus(const String &key) const;
    void waitForStems();
    void previewStemMix(const String &,const native::stem::Mix &);
    void checkStemErrors() const;
    std::shared_ptr<native::vst3::Processor> external(const String &key) const;
    void captureExternalState(var &) const;
    StringArray unsupported;
private:
    struct Effect;
    std::vector<std::unique_ptr<Effect>> effects;
};
}
