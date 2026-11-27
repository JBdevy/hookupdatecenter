// Adapt Apple's Audio Unit render API to the same insert buffer as VST3.
AudioComponentDescription hostedAudioUnitDescription(NSString *identifier) {
    unsigned type = 0, subtype = 0, manufacturer = 0;
    if (sscanf(identifier.UTF8String ?: "", "AU-%8x-%8x-%8x", &type, &subtype, &manufacturer) != 3)
        return {};
    return {type, subtype, manufacturer, 0, 0};
}

class HostedAudioUnit {
public:
    AUAudioUnit *unit;
    AUParameterTree *tree;
    std::vector<AUParameter *> parameters;
    const double rate;
    bool instrument;
    static constexpr unsigned capacity = 4096;

    HostedAudioUnit(AVAudioUnit *instance, double sampleRate, bool isInstrument, bool offline, NSString *state)
        : unit(instance.AUAudioUnit), rate(sampleRate), instrument(isInstrument), node(instance) {
        if (!unit) throw std::runtime_error("Audio Unit is unavailable.");
        unit.renderingOffline = offline;
        restore(state);

        auto inputs = unit.inputBusses;
        auto outputs = unit.outputBusses;
        if (outputs.count == 0 || (!instrument && inputs.count == 0))
            throw std::runtime_error("This Audio Unit does not have a supported audio bus.");
        outputChannels = configureBus(outputs[0]);
        if (inputs.count) inputChannels = configureBus(inputs[0]);
        if (!outputChannels || (inputs.count && !inputChannels))
            throw std::runtime_error("This Audio Unit requires a channel layout other than mono or stereo.");
        for (NSUInteger bus = 1; bus < inputs.count; ++bus) inputs[bus].enabled = NO;
        for (NSUInteger bus = 1; bus < outputs.count; ++bus) outputs[bus].enabled = NO;
        unit.maximumFramesToRender = capacity;

        auto host = this;
        if (inputChannels && node.audioUnit) {
            // The AUv2 bridge uses the legacy input callback. Leaving it
            // disconnected produces kAudioUnitErr_NoConnection in render.
            const AURenderCallbackStruct callback{pullLegacy, host};
            if (AudioUnitSetProperty(node.audioUnit, kAudioUnitProperty_SetRenderCallback,
                                     kAudioUnitScope_Input, 0, &callback, sizeof(callback)) != noErr)
                throw std::runtime_error("Could not connect the Audio Unit input.");
        }
        render = unit.renderBlock;
        schedule = unit.scheduleMIDIEventBlock;
        unit.musicalContextBlock = ^BOOL(double *tempo, double *numerator, NSInteger *denominator,
                                         double *beat, NSInteger *nextBeat, double *measure) {
            const auto &position = host->transport;
            if (tempo) *tempo = position.tempo;
            if (numerator) *numerator = position.numerator;
            if (denominator) *denominator = position.denominator;
            if (beat) *beat = position.quarterNotes;
            if (nextBeat) *nextBeat = llround((ceil(position.quarterNotes) - position.quarterNotes) * host->rate * 60 / position.tempo);
            if (measure) *measure = position.barStartQuarterNotes;
            return YES;
        };
        unit.transportStateBlock = ^BOOL(AUHostTransportStateFlags *flags, double *sample, double *start, double *end) {
            const auto &position = host->transport;
            if (flags) *flags = position.playing ? AUHostTransportStateMoving : AUHostTransportStateFlags(0);
            if (sample) *sample = position.seconds * host->rate;
            if (start) *start = 0;
            if (end) *end = 0;
            return YES;
        };
        NSError *error = nil;
        if (![unit allocateRenderResourcesAndReturnError:&error]) {
            unit.musicalContextBlock = nil;
            unit.transportStateBlock = nil;
            throw std::runtime_error(error.localizedDescription.UTF8String ?: "Could not prepare the Audio Unit.");
        }
        tree = unit.parameterTree;
        for (AUParameter *parameter in tree.allParameters) {
            if ((parameter.flags & kAudioUnitParameterFlag_IsReadable) &&
                (parameter.flags & kAudioUnitParameterFlag_IsWritable) && parameter.maxValue > parameter.minValue)
                parameters.push_back(parameter);
        }
        std::sort(parameters.begin(), parameters.end(), [](AUParameter *a, AUParameter *b) { return a.address < b.address; });
        pull = ^AUAudioUnitStatus(AudioUnitRenderActionFlags *flags, const AudioTimeStamp *timestamp,
                                 AUAudioFrameCount frames, NSInteger bus, AudioBufferList *buffers) {
            return host->provideInput(flags, timestamp, frames, bus, buffers);
        };
    }
    ~HostedAudioUnit() {
        unit.musicalContextBlock = nil;
        unit.transportStateBlock = nil;
        [unit deallocateRenderResources];
    }

    void send(unsigned offset, const MIDI &midi) {
        if (!schedule) return;
        const uint8 bytes[]{midi.status, midi.data1, midi.data2};
        const auto kind = midi.status & 0xf0;
        schedule(AUEventSampleTimeImmediate + offset, 0, kind == 0xc0 || kind == 0xd0 ? 2 : 3, bytes);
    }
    void process(AudioBufferList *buffer, unsigned count, const jaras::PluginTransport &position, bool replaceInput = false) {
        if (count > capacity || !count) return;
        transport = position;
        for (unsigned c = 0; c < inputChannels; ++c) {
            const auto data = !replaceInput && c < buffer->mNumberBuffers ? static_cast<const float *>(buffer->mBuffers[c].mData) : nullptr;
            if (data) std::copy_n(data, count, input[c].data());
            else std::fill_n(input[c].data(), count, 0.f);
        }
        if (!replaceInput && inputChannels == 1 && buffer->mNumberBuffers > 1) {
            const auto right = static_cast<const float *>(buffer->mBuffers[1].mData);
            if (right) for (unsigned f = 0; f < count; ++f) input[0][f] = (input[0][f] + right[f]) * .5f;
        }
        struct StereoBufferList { UInt32 count; AudioBuffer buffers[2]; };
        StereoBufferList output{outputChannels, {{1, UInt32(count * sizeof(float)), samples[0].data()},
                                                {1, UInt32(count * sizeof(float)), samples[1].data()}}};
        for (unsigned c = 0; c < outputChannels; ++c) std::fill_n(samples[c].data(), count, 0.f);
        AudioTimeStamp stamp{};
        stamp.mFlags = kAudioTimeStampSampleTimeValid;
        stamp.mSampleTime = sampleTime;
        sampleTime += count;
        AudioUnitRenderActionFlags flags = 0;
        if (render(&flags, &stamp, count, 0, reinterpret_cast<AudioBufferList *>(&output), pull) != noErr) return;
        for (unsigned c = 0; c < buffer->mNumberBuffers && c < 2; ++c) {
            auto destination = static_cast<float *>(buffer->mBuffers[c].mData);
            const auto source = static_cast<const float *>(output.buffers[std::min(c, outputChannels - 1)].mData);
            if (!destination) continue;
            for (unsigned f = 0; f < count; ++f) {
                const auto sample = source && std::isfinite(source[f]) ? source[f] : 0.f;
                destination[f] = (instrument ? destination[f] : 0.f) + sample;
            }
        }
    }
    NSDictionary *state() const {
        NSDictionary *document = unit.fullStateForDocument ?: unit.fullState;
        if (!document) return nil;
        NSData *blob = [NSPropertyListSerialization dataWithPropertyList:document format:NSPropertyListBinaryFormat_v1_0 options:0 error:nil];
        return blob ? @{@"componentState":[blob base64EncodedStringWithOptions:0]} : nil;
    }
    static double normalized(AUParameter *p, AUValue value) {
        return (value - p.minValue) / (p.maxValue - p.minValue);
    }
private:
    AVAudioUnit *node;
    static OSStatus pullLegacy(void *context, AudioUnitRenderActionFlags *flags, const AudioTimeStamp *time,
                               UInt32 bus, UInt32 frames, AudioBufferList *buffers) {
        return static_cast<HostedAudioUnit *>(context)->provideInput(flags, time, frames, bus, buffers);
    }
    unsigned inputChannels = 0, outputChannels = 0;
    double sampleTime = 0;
    jaras::PluginTransport transport{};
    AURenderBlock render;
    AUScheduleMIDIEventBlock schedule;
    AURenderPullInputBlock pull;
    std::array<std::array<float, capacity>, 2> input{}, samples{};

    unsigned configureBus(AUAudioUnitBus *bus) {
        for (unsigned channels : {2u, 1u}) {
            auto format = [[AVAudioFormat alloc] initStandardFormatWithSampleRate:rate channels:channels];
            if ([bus setFormat:format error:nil]) return channels;
        }
        return 0;
    }
    void restore(NSString *state) {
        if (!state.length) return;
        NSData *data = [[NSData alloc] initWithBase64EncodedString:state options:0];
        id decoded = data ? [NSPropertyListSerialization propertyListWithData:data options:NSPropertyListImmutable format:nil error:nil] : nil;
        if (![decoded isKindOfClass:NSDictionary.class]) throw std::runtime_error("Invalid saved Audio Unit state.");
        unit.fullStateForDocument = decoded;
    }
    AUAudioUnitStatus provideInput(AudioUnitRenderActionFlags *flags, const AudioTimeStamp *timestamp,
                                  AUAudioFrameCount frames, NSInteger bus, AudioBufferList *buffers) {
        if (frames > capacity) return kAudioUnitErr_TooManyFramesToProcess;
        for (unsigned c = 0; c < buffers->mNumberBuffers; ++c) {
            const bool connected = bus == 0 && c < inputChannels;
            auto &entry = buffers->mBuffers[c];
            auto source = connected ? input[c].data() : nullptr;
            if (!entry.mData) {
                // Both buses use mono/stereo float buffers. An unused
                // sidechain may ask the host to point it at silence.
                entry.mData = source ?: silence.data();
            } else if (source) std::copy_n(source, frames, static_cast<float *>(entry.mData));
            else memset(entry.mData, 0, frames * sizeof(float));
            entry.mDataByteSize = UInt32(frames * sizeof(float));
        }
        if (bus != 0 || !inputChannels) *flags |= kAudioUnitRenderAction_OutputIsSilence;
        return noErr;
    }
    std::array<float, capacity> silence{};
};
