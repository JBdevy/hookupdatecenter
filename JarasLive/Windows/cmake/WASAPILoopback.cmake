# Extend only CatLive's private JUCE 8.0.15 copy. Upstream remains untouched.
# WASAPI loopback captures a render endpoint using IAudioCaptureClient.
# https://learn.microsoft.com/windows/win32/coreaudio/loopback-recording
function(catlive_prepare_loopback source destination)
    set(relative modules/juce_audio_devices/juce_audio_devices.h)
    file(READ "${source}/${relative}" content)
    string(REPLACE "\r\n" "\n" content "${content}")
    string(SHA256 hash "${content}")
    if(NOT hash STREQUAL "f7f17b8fae5c0551684e9bfbdc6f62eb6957e74db70171f9d5abb8512132ee26")
        message(FATAL_ERROR "Loopback patch requires unmodified JUCE 8.0.15: ${relative}")
    endif()
    string(REPLACE [=[        sharedLowLatency
]=] [=[        sharedLowLatency,
        sharedLoopback // CatLive: capture a Windows render endpoint
]=] content "${content}")
    set(existing "")
    if(EXISTS "${destination}/${relative}")
        file(READ "${destination}/${relative}" existing)
    endif()
    if(NOT existing STREQUAL content)
        file(WRITE "${destination}/${relative}" "${content}")
    endif()
    set(relative modules/juce_audio_devices/audio_io/juce_AudioDeviceManager.cpp)
    file(READ "${source}/${relative}" content)
    string(REPLACE "\r\n" "\n" content "${content}")
    string(SHA256 hash "${content}")
    if(NOT hash STREQUAL "74f0659477a1712e9b5e7012c3c72ae69b1213ef7c06b4ba77fb2c9a5269ad25")
        message(FATAL_ERROR "Loopback patch requires unmodified JUCE 8.0.15: ${relative}")
    endif()
    string(REPLACE [=[    addIfNotNull (list, AudioIODeviceType::createAudioIODeviceType_WASAPI (WASAPIDeviceMode::sharedLowLatency));]=] [=[    addIfNotNull (list, AudioIODeviceType::createAudioIODeviceType_WASAPI (WASAPIDeviceMode::sharedLowLatency));
    addIfNotNull (list, AudioIODeviceType::createAudioIODeviceType_WASAPI (WASAPIDeviceMode::sharedLoopback));]=] content "${content}")
    set(existing "")
    if(EXISTS "${destination}/${relative}")
        file(READ "${destination}/${relative}" existing)
    endif()
    if(NOT existing STREQUAL content)
        file(WRITE "${destination}/${relative}" "${content}")
    endif()
    set(relative modules/juce_audio_devices/native/juce_WASAPI_windows.cpp)
    file(READ "${source}/${relative}" content)
    string(REPLACE "\r\n" "\n" content "${content}")
    string(SHA256 hash "${content}")
    if(NOT hash STREQUAL "93d0418b87529d62ce7e3001660ba233318505647c9ac78094bca688bae2c2d5")
        message(FATAL_ERROR "Loopback patch requires unmodified JUCE 8.0.15: ${relative}")
    endif()
    string(REPLACE [=[return deviceMode == WASAPIDeviceMode::shared;]=] [=[return deviceMode == WASAPIDeviceMode::shared || deviceMode == WASAPIDeviceMode::sharedLoopback;]=] content "${content}")
    string(REPLACE [=[if (deviceMode == WASAPIDeviceMode::shared)]=] [=[if (deviceMode == WASAPIDeviceMode::shared || deviceMode == WASAPIDeviceMode::sharedLoopback)]=] content "${content}")
    # Input and output can share the same IMMDevice in loopback. Identify
    # callbacks by stream, otherwise output events are mistaken for input.
    string(REPLACE [=[struct WASAPIDeviceBaseDelegate]=] [=[class WASAPIDeviceBase;

struct WASAPIDeviceBaseDelegate]=] content "${content}")
    string(REPLACE [=[(IMMDevice*)]=] [=[(WASAPIDeviceBase*)]=] content "${content}")
    string(REPLACE [=[(IMMDevice* d) override]=] [=[(WASAPIDeviceBase* d) override]=] content "${content}")
    string(REPLACE [=[inputDevice->device != d]=] [=[inputDevice.get() != d]=] content "${content}")
    string(REPLACE [=[WASAPIDeviceBaseDelegate& delegateIn)]=] [=[WASAPIDeviceBaseDelegate& delegateIn, bool captureLoopbackIn = false)]=] content "${content}")
    string(REPLACE [=[delegate (delegateIn)]=] [=[delegate (delegateIn), captureLoopback (captureLoopbackIn)]=] content "${content}")
    string(REPLACE [=[    WASAPIDeviceBaseDelegate& delegate;]=] [=[    WASAPIDeviceBaseDelegate& delegate;
    const bool captureLoopback;]=] content "${content}")
    string(REPLACE [=[        DWORD streamFlags = 0x40000; /*AUDCLNT_STREAMFLAGS_EVENTCALLBACK*/]=] [=[        DWORD streamFlags = 0x40000; /*AUDCLNT_STREAMFLAGS_EVENTCALLBACK*/
        if (captureLoopback) streamFlags |= 0x20000; /*AUDCLNT_STREAMFLAGS_LOOPBACK*/]=] content "${content}")
    string(REPLACE [=[            GUID session;]=] [=[            GUID session{};]=] content "${content}")
    string(REPLACE [=[            if (deviceId == inputDeviceId && flow == eCapture)
                inputDevice.reset (new WASAPIInputDevice (device, deviceMode, *this));
            else if (deviceId == outputDeviceId && flow == eRender)]=] [=[            const bool loopback = deviceMode == WASAPIDeviceMode::sharedLoopback;
            if (deviceId == inputDeviceId && flow == (loopback ? eRender : eCapture))
                inputDevice.reset (new WASAPIInputDevice (device, deviceMode, *this, loopback));
            if (deviceId == outputDeviceId && flow == eRender)]=] content "${content}")
    string(REPLACE [=[        result.outputDeviceNames.appendNumbersToDuplicates (false, false);]=] [=[        result.outputDeviceNames.appendNumbersToDuplicates (false, false);

        if (deviceMode == WASAPIDeviceMode::sharedLoopback)
        {
            result.inputDeviceNames = result.outputDeviceNames;
            result.inputDeviceIds = result.outputDeviceIds;
        }]=] content "${content}")
    string(REPLACE [=[        if (mode == WASAPIDeviceMode::shared)            return "Windows Audio";]=] [=[        if (mode == WASAPIDeviceMode::sharedLoopback)    return "Windows Audio (Loopback)";
        if (mode == WASAPIDeviceMode::shared)            return "Windows Audio";]=] content "${content}")
    string(REPLACE [=[            inChannels.add ("Input channel " + String (i));]=] [=[            inChannels.add ((deviceMode == WASAPIDeviceMode::sharedLoopback ? "Loopback channel " : "Input channel ") + String (i));]=] content "${content}")
    string(REPLACE [=[        uint8* inputData;
        UINT32 numSamplesAvailable;
        DWORD flags;

        while (captureClient->GetBuffer (&inputData, &numSamplesAvailable, &flags, nullptr, nullptr) != MAKE_HRESULT (0, 0x889, 0x1) /* AUDCLNT_S_BUFFER_EMPTY */)]=] [=[        uint8* inputData = nullptr;
        UINT32 numSamplesAvailable = 0;
        DWORD flags = 0;

        while (captureClient->GetBuffer (&inputData, &numSamplesAvailable, &flags, nullptr, nullptr) == S_OK && numSamplesAvailable > 0)]=] content "${content}")
    string(REPLACE [=[        outs.clear();

        while (! threadShouldExit())]=] [=[        outs.clear();
        double inputOnlyNextCallback = Time::getMillisecondCounterHiRes();

        while (! threadShouldExit())]=] content "${content}")
    string(REPLACE [=[                    if (WaitForSingleObject (inputDevice->clientEvent, 1000) == WAIT_TIMEOUT)
                        break;

                    inputDevice->handleDeviceBuffer();

                    if (inputDevice->getNumSamplesInReservoir() < bufferSize)
                        continue;]=] [=[                    const bool loopback = deviceMode == WASAPIDeviceMode::sharedLoopback;
                    if (loopback)
                    {
                        // A silent endpoint may stop sending packets. Clock zero-filled
                        // callbacks by elapsed time, never once per partial packet/event.
                        const auto remaining = inputOnlyNextCallback - Time::getMillisecondCounterHiRes();
                        WaitForSingleObject (inputDevice->clientEvent, (DWORD) jmax (0, (int) std::ceil (remaining)));
                        inputDevice->handleDeviceBuffer();
                        const auto now = Time::getMillisecondCounterHiRes();
                        if (now < inputOnlyNextCallback)
                            continue;
                        const auto period = 1000.0 * bufferSize / currentSampleRate;
                        inputOnlyNextCallback += period;
                        if (inputOnlyNextCallback < now - 4 * period)
                            inputOnlyNextCallback = now + period;
                    }
                    else
                    {
                        if (WaitForSingleObject (inputDevice->clientEvent, 1000) == WAIT_TIMEOUT)
                            break;
                        inputDevice->handleDeviceBuffer();
                        if (inputDevice->getNumSamplesInReservoir() < bufferSize)
                            continue;
                    }]=] content "${content}")
    string(REPLACE [=[delegate.deviceOpened (device);]=] [=[delegate.deviceOpened (this);]=] content "${content}")
    string(REPLACE [=[delegate.deviceSampleRateChanged (device);]=] [=[delegate.deviceSampleRateChanged (this);]=] content "${content}")
    string(REPLACE [=[delegate.deviceSessionBecameInactive (device);]=] [=[delegate.deviceSessionBecameInactive (this);]=] content "${content}")
    string(REPLACE [=[delegate.deviceSessionExpired (device);]=] [=[delegate.deviceSessionExpired (this);]=] content "${content}")
    string(REPLACE [=[delegate.deviceSessionBecameActive (device);]=] [=[delegate.deviceSessionBecameActive (this);]=] content "${content}")
    set(existing "")
    if(EXISTS "${destination}/${relative}")
        file(READ "${destination}/${relative}" existing)
    endif()
    if(NOT existing STREQUAL content)
        file(WRITE "${destination}/${relative}" "${content}")
    endif()
endfunction()
