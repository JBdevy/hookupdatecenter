#pragma once
#include "Common.h"

namespace catlive::audioDeviceChannels {
// DeviceManager's default is the two channels requested at startup. CatLive
// routes tracks to physical outputs, so every advertised channel must be open.
inline void enableAvailable(AudioDeviceManager::AudioDeviceSetup &setup,
                            int inputCount, int outputCount) {
    setup.useDefaultInputChannels = false;
    setup.useDefaultOutputChannels = false;
    setup.inputChannels.clear();
    setup.outputChannels.clear();
    if (setup.inputDeviceName.isNotEmpty())
        setup.inputChannels.setRange(0, jlimit(0, 128, inputCount), true);
    if (setup.outputDeviceName.isNotEmpty())
        setup.outputChannels.setRange(0, jlimit(0, 128, outputCount), true);
}
inline String enableAvailable(AudioDeviceManager &manager) {
    auto *device = manager.getCurrentAudioDevice();
    if (!device) return {};
    const auto previous = manager.getAudioDeviceSetup();
    auto setup = previous;
    enableAvailable(setup, device->getInputChannelNames().size(), device->getOutputChannelNames().size());
    if (setup == previous) return {};
    return manager.setAudioDeviceSetup(setup, true);
}
}
