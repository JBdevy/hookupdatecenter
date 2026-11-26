#pragma once
#include "pluginterfaces/vst/ivsteditcontroller.h"
#include <unordered_set>

namespace jaras {
// Controller state can contain ordinary parameter edits that a separate DSP
// component has not received. MIDI proxies and program selectors are commands,
// not a snapshot of the instrument: their getter often returns zero regardless
// of the loaded preset. Never synthesize those commands while restoring state.
inline bool restoreControllerParameter(const Steinberg::Vst::ParameterInfo& info,
                                       bool hasControllerState,
                                       const std::unordered_set<Steinberg::Vst::ParamID>& midiParameters) {
    using Info = Steinberg::Vst::ParameterInfo;
    return hasControllerState &&
        !(info.flags & (Info::kIsReadOnly | Info::kIsHidden | Info::kIsProgramChange)) &&
        midiParameters.find(info.id) == midiParameters.end();
}
}
