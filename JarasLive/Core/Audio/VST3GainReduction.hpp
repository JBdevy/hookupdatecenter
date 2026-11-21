#pragma once

#include "pluginterfaces/vst/ivsteditcontroller.h"
#include "pluginterfaces/vst/ivstparameterchanges.h"
#include "pluginterfaces/vst/ivstparameterfunctionname.h"
#include "pluginterfaces/vst/ivstunits.h"

#include <algorithm>
#include <array>
#include <atomic>
#include <cmath>
#include <limits>

namespace catlive::audio {
// Read the plug-in's announced gain-reduction parameter. The renderer writes
// only an atomic measurement; querying the controller is a setup operation.
class VST3GainReduction final : public Steinberg::Vst::IParameterChanges {
    class Queue final : public Steinberg::Vst::IParamValueQueue {
    public:
        Steinberg::Vst::ParamID id = Steinberg::Vst::kNoParamId;
        Steinberg::int32 offset = 0;
        Steinberg::Vst::ParamValue value = 0;
        bool valid = false;

        Steinberg::tresult PLUGIN_API queryInterface(const Steinberg::TUID iid, void **out) override {
            const bool match = Steinberg::FUnknownPrivate::iidEqual(iid, Steinberg::INLINE_UID_OF(FUnknown)) ||
                Steinberg::FUnknownPrivate::iidEqual(iid, Steinberg::Vst::INLINE_UID_OF(IParamValueQueue));
            *out = match ? this : nullptr;
            return match ? Steinberg::kResultOk : Steinberg::kNoInterface;
        }
        Steinberg::uint32 PLUGIN_API addRef() override { return 1; }
        Steinberg::uint32 PLUGIN_API release() override { return 1; }
        Steinberg::Vst::ParamID PLUGIN_API getParameterId() override { return id; }
        Steinberg::int32 PLUGIN_API getPointCount() override { return valid ? 1 : 0; }
        Steinberg::tresult PLUGIN_API getPoint(Steinberg::int32 index, Steinberg::int32 &at,
                                                  Steinberg::Vst::ParamValue &out) override {
            if (index != 0 || !valid) return Steinberg::kInvalidArgument;
            at = offset; out = value;
            return Steinberg::kResultOk;
        }
        Steinberg::tresult PLUGIN_API addPoint(Steinberg::int32 at, Steinberg::Vst::ParamValue next,
                                                  Steinberg::int32 &index) override {
            index = 0;
            if (std::isfinite(next) && (!valid || at >= offset)) {
                offset = at; value = std::clamp(next, 0.0, 1.0); valid = true;
            }
            return Steinberg::kResultOk;
        }
    } queue;
    std::array<float, 257> decibels{};
    std::atomic<float> value{0};
    bool requested = false;

public:
    void configure(Steinberg::Vst::IEditController *controller) {
        using namespace Steinberg;
        using namespace Steinberg::Vst;
        IParameterFunctionName *functions = nullptr;
        if (!controller || controller->queryInterface(IParameterFunctionName_iid,
            reinterpret_cast<void **>(&functions)) != kResultOk || !functions) return;
        ParamID id = kNoParamId;
        const auto found = functions->getParameterIDFromFunctionName(kRootUnitId, FunctionNameType::kCompGainReduction, id);
        functions->release();
        if (found != kResultOk || id == kNoParamId) return;
        for (std::size_t i = 0; i < decibels.size(); ++i) {
            const auto plain = controller->normalizedParamToPlain(id, double(i) / (decibels.size() - 1));
            decibels[i] = std::isfinite(plain) ? float(std::min(120., std::abs(plain))) : 0.f;
        }
        queue.id = id;
    }

    bool supported() const noexcept { return queue.id != Steinberg::Vst::kNoParamId; }
    void begin() noexcept { requested = false; queue.valid = false; }
    void end() noexcept {
        if (!queue.valid) return;
        const auto position = queue.value * (decibels.size() - 1);
        const auto index = std::min(decibels.size() - 2, static_cast<std::size_t>(position));
        const auto db = decibels[index] + (decibels[index + 1] - decibels[index]) * float(position - index);
        value.store(db, std::memory_order_relaxed);
    }
    float read() const noexcept { return value.load(std::memory_order_relaxed); }

    Steinberg::tresult PLUGIN_API queryInterface(const Steinberg::TUID iid, void **out) override {
        const bool match = Steinberg::FUnknownPrivate::iidEqual(iid, Steinberg::INLINE_UID_OF(FUnknown)) ||
            Steinberg::FUnknownPrivate::iidEqual(iid, Steinberg::Vst::INLINE_UID_OF(IParameterChanges));
        *out = match ? this : nullptr;
        return match ? Steinberg::kResultOk : Steinberg::kNoInterface;
    }
    Steinberg::uint32 PLUGIN_API addRef() override { return 1; }
    Steinberg::uint32 PLUGIN_API release() override { return 1; }
    Steinberg::int32 PLUGIN_API getParameterCount() override { return requested ? 1 : 0; }
    Steinberg::Vst::IParamValueQueue *PLUGIN_API getParameterData(Steinberg::int32 index) override {
        return requested && index == 0 ? &queue : nullptr;
    }
    Steinberg::Vst::IParamValueQueue *PLUGIN_API addParameterData(
        const Steinberg::Vst::ParamID &id, Steinberg::int32 &index) override {
        if (!supported() || id != queue.id) return nullptr;
        requested = true; index = 0;
        return &queue;
    }
};
}
