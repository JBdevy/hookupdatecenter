#pragma once
#include "AudioDeviceChannels.h"

namespace catlive {
// Keep the user's routing policy separate from JUCE's resolved device names.
// ASIO selects its own driver, so only system endpoint backends offer this mode.
class SystemAudioDefaults final : private ChangeListener, private Timer {
    struct Policy { CriticalSection ownersLock; bool input = false, output = false, loaded = false; std::vector<SystemAudioDefaults *> owners; };
    static std::shared_ptr<Policy> policyFor(AudioDeviceManager &manager) {
        static CriticalSection policiesLock;
        const ScopedLock lock(policiesLock);
        static std::map<AudioDeviceManager *, std::weak_ptr<Policy>> policies;
        for (auto it = policies.begin(); it != policies.end();) {
            if (it->second.expired()) it = policies.erase(it); else ++it;
        }
        auto result = policies[&manager].lock();
        if (!result) { result = std::make_shared<Policy>(); policies[&manager] = result; }
        return result;
    }
    AudioDeviceManager &manager;
    std::shared_ptr<Policy> policy;
  public:
    explicit SystemAudioDefaults(AudioDeviceManager &owner, std::function<bool()> allowed)
        : manager(owner), policy(policyFor(owner)), input(policy->input), output(policy->output), canSwitch(std::move(allowed)) { const ScopedLock lock(policy->ownersLock); policy->owners.push_back(this); }
    ~SystemAudioDefaults() override {
        stop(); const ScopedLock lock(policy->ownersLock); auto &owners = policy->owners;
        owners.erase(std::remove(owners.begin(), owners.end(), this), owners.end());
    }
    bool &input, &output;
    bool supported() const {
        const auto type = manager.getCurrentAudioDeviceType();
        return type.startsWith("Windows Audio") || type == "DirectSound";
    }
    String deviceName(bool isInput) const {
        if (auto *type = manager.getCurrentDeviceTypeObject()) {
            const auto names = type->getDeviceNames(isInput);
            const int index = type->getDefaultDeviceIndex(isInput);
            if (isPositiveAndBelow(index, names.size())) return names[index];
        }
        return {};
    }
    void read(const XmlElement *xml) {
        if (policy->loaded) return;
        policy->loaded = true;
        input = xml && xml->getBoolAttribute("catliveFollowSystemInput", false);
        output = xml && xml->getBoolAttribute("catliveFollowSystemOutput", false);
    }
    void write(XmlElement &xml) const {
        xml.setAttribute("catliveFollowSystemInput", input);
        xml.setAttribute("catliveFollowSystemOutput", output);
    }
    String start(const XmlElement *xml) {
        if (!listening) { read(xml); manager.addChangeListener(this); listening = true; }
        return apply();
    }
    void stop() { stopTimer(); if (listening) { manager.removeChangeListener(this); listening = false; } }
    String apply() {
        if (!supported() || (!input && !output) || applying) return {};
        auto setup = manager.getAudioDeviceSetup();
        const auto previous = setup;
        if (input) setup.inputDeviceName = deviceName(true);
        if (output) setup.outputDeviceName = deviceName(false);
        if (setup.inputDeviceName == previous.inputDeviceName && setup.outputDeviceName == previous.outputDeviceName) return {};
        {
            const ScopedLock lock(policy->ownersLock);
            for (const auto *owner : policy->owners)
                if (owner->listening && !owner->canSwitch()) { startTimer(500); return {}; }
        }
        const ScopedValueSetter<bool> guard(applying, true);
        // Open conservatively, then enable the new endpoint's advertised channels.
        setup.useDefaultInputChannels = setup.useDefaultOutputChannels = false;
        setup.inputChannels.clear(); setup.outputChannels.clear();
        if (setup.inputDeviceName.isNotEmpty()) setup.inputChannels.setBit(0);
        if (setup.outputDeviceName.isNotEmpty()) setup.outputChannels.setBit(0);
        auto error = manager.setAudioDeviceSetup(setup, true);
        if (error.isEmpty()) error = audioDeviceChannels::enableAvailable(manager);
        return error;
    }
  private:
    std::function<bool()> canSwitch;
    bool listening = false, applying = false;
    void changeListenerCallback(ChangeBroadcaster *) override { apply(); }
    void timerCallback() override { stopTimer(); apply(); }
};
}
