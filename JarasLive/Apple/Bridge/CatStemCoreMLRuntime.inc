// Included inside CatStemRealtime after State/Resampler. Imports remain in
// JarasStemSeparator.mm so Objective-C framework declarations stay global.
// No Core ML operation, file access, mutex or allocation runs in the AU block.
class MobileModel {
    static constexpr unsigned context = CatStemMobile::Spectrogram::context;
    static constexpr unsigned overlapFrames = 1024;
    static constexpr unsigned predictedFrames = hop + overlapFrames;
    MLModel *model = nil;
    MLMultiArray *audioInput = nil, *spectrumInput = nil;
    MLDictionaryFeatureProvider *inputs = nil;
    CatStemMobile::Spectrogram transform;
    std::vector<float> history = std::vector<float>(context * 2);
    std::vector<float> spectrum = std::vector<float>(CatStemMobile::Spectrogram::values);
    std::vector<float> timeBranch = std::vector<float>(context * 2);
    std::vector<float> inverse = std::vector<float>(context * 2);
    std::vector<float> prediction = std::vector<float>(4 * 2 * predictedFrames);
    std::vector<float> previousTail = std::vector<float>(4 * 2 * overlapFrames);
    bool hasPreviousTail = false;

    static std::runtime_error error(NSError *failure, const char *message) {
        return std::runtime_error(failure.localizedDescription.UTF8String ?: message);
    }
    static bool shapeEquals(NSArray<NSNumber *> *actual, NSArray<NSNumber *> *expected) {
        return [actual isEqualToArray:expected];
    }
    static void requireTensor(NSDictionary<NSString *, MLFeatureDescription *> *features,
                              NSString *name, NSArray<NSNumber *> *shape) {
        MLFeatureDescription *feature = features[name];
        if (!feature || feature.type != MLFeatureTypeMultiArray ||
            feature.multiArrayConstraint.dataType != MLMultiArrayDataTypeFloat32 ||
            !shapeEquals(feature.multiArrayConstraint.shape, shape))
            throw std::runtime_error("The CatStem Core ML model uses an incompatible tensor contract.");
    }
    // Core ML may pad tensor strides. Only copy one source, respecting its
    // actual layout, instead of assuming the prediction is tightly packed.
    static void copySource(MLMultiArray *array, unsigned source, float *destination,
                           NSArray<NSNumber *> *expected) {
        if (!array || array.dataType != MLMultiArrayDataTypeFloat32 || !shapeEquals(array.shape, expected))
            throw std::runtime_error("The CatStem Core ML model returned an invalid tensor.");
        const float *base = static_cast<const float *>(array.dataPointer);
        const size_t rank = array.shape.count;
        std::array<size_t, 5> shape{}, stride{};
        size_t count = 1;
        for (size_t i = 0; i < rank; ++i) {
            shape[i] = array.shape[i].unsignedIntegerValue;
            stride[i] = array.strides[i].unsignedIntegerValue;
            if (i >= 2) count *= shape[i];
        }
        bool contiguous = stride[rank - 1] == 1;
        for (size_t i = rank - 1; i > 2; --i)
            contiguous = contiguous && stride[i - 1] == stride[i] * shape[i];
        base += source * stride[1];
        if (contiguous) { std::copy_n(base, count, destination); return; }
        for (size_t index = 0; index < count; ++index) {
            size_t remainder = index, offset = 0;
            for (size_t i = rank; i-- > 2;) {
                offset += (remainder % shape[i]) * stride[i]; remainder /= shape[i];
            }
            destination[index] = base[offset];
        }
    }
    void estimate() {
        std::copy(history.begin(), history.end(), static_cast<float *>(audioInput.dataPointer));
        transform.encode(history.data(), static_cast<float *>(spectrumInput.dataPointer));
        NSError *failure = nil;
        id<MLFeatureProvider> result = [model predictionFromFeatures:inputs error:&failure];
        if (!result) throw error(failure, "CatStem Core ML prediction failed.");
        MLMultiArray *spectral = [result featureValueForName:@"spectrum_out"].multiArrayValue;
        MLMultiArray *temporal = [result featureValueForName:@"audio_out"].multiArrayValue;
        // The network predicts drums,bass,other,vocals,guitar,piano. Other is
        // reconstructed as the mixture residual below, just like the Mac engine.
        static constexpr unsigned sourceOrder[4] = {3, 0, 1, 4};
        constexpr unsigned start = context - rightContext - hop;
        for (unsigned stem = 0; stem < 4; ++stem) {
            copySource(spectral, sourceOrder[stem], spectrum.data(), @[@1, @6, @4, @2048, @44]);
            copySource(temporal, sourceOrder[stem], timeBranch.data(), @[@1, @6, @2, @44100]);
            transform.decode(spectrum.data(), inverse.data());
            for (unsigned channel = 0; channel < 2; ++channel)
                for (unsigned frame = 0; frame < predictedFrames; ++frame) {
                    const float value = inverse[channel * context + start + frame] + timeBranch[channel * context + start + frame];
                    if (!std::isfinite(value)) throw std::runtime_error("CatStem returned nonfinite audio.");
                    prediction[(stem * 2 + channel) * predictedFrames + frame] = value;
                }
        }
    }
public:
    explicit MobileModel(NSURL *url) {
        MLModelConfiguration *configuration = [MLModelConfiguration new];
        configuration.computeUnits = MLComputeUnitsAll;
        NSError *failure = nil;
        model = [MLModel modelWithContentsOfURL:url configuration:configuration error:&failure];
        if (!model) throw error(failure, "Could not load the CatStem Core ML model.");
        NSDictionary *metadata = model.modelDescription.metadata[MLModelCreatorDefinedKey];
        if (![metadata[@"catlive.source_checkpoint"] isEqual:@"5c90dfd2-34c22ccb"])
            throw std::runtime_error("The CatStem Core ML model has an unexpected source identity.");
        requireTensor(model.modelDescription.inputDescriptionsByName, @"audio", @[@1, @2, @44100]);
        requireTensor(model.modelDescription.inputDescriptionsByName, @"spectrum", @[@1, @4, @2048, @44]);
        requireTensor(model.modelDescription.outputDescriptionsByName, @"spectrum_out", @[@1, @6, @4, @2048, @44]);
        requireTensor(model.modelDescription.outputDescriptionsByName, @"audio_out", @[@1, @6, @2, @44100]);
        audioInput = [[MLMultiArray alloc] initWithShape:@[@1, @2, @44100] dataType:MLMultiArrayDataTypeFloat32 error:&failure];
        if (!audioInput) throw error(failure, "Could not allocate CatStem input audio.");
        spectrumInput = [[MLMultiArray alloc] initWithShape:@[@1, @4, @2048, @44] dataType:MLMultiArrayDataTypeFloat32 error:&failure];
        if (!spectrumInput) throw error(failure, "Could not allocate the CatStem input spectrum.");
        inputs = [[MLDictionaryFeatureProvider alloc] initWithDictionary:@{
            @"audio": [MLFeatureValue featureValueWithMultiArray:audioInput],
            @"spectrum": [MLFeatureValue featureValueWithMultiArray:spectrumInput]
        } error:&failure];
        if (!inputs) throw error(failure, "Could not prepare CatStem model inputs.");
    }
    void reset() {
        std::fill(history.begin(), history.end(), 0);
        std::fill(previousTail.begin(), previousTail.end(), 0);
        hasPreviousTail = false;
    }
    void warmup() { estimate(); reset(); }
    // Planar output [5,hop,2], same protocol as the desktop worker.
    void process(const float *pcm, float *output) {
        for (unsigned channel = 0; channel < 2; ++channel) {
            float *target = history.data() + channel * context;
            std::memmove(target, target + hop, (context - hop) * sizeof(float));
            for (unsigned frame = 0; frame < hop; ++frame) target[context - hop + frame] = pcm[frame * 2 + channel];
        }
        const bool silent = std::all_of(history.begin(), history.end(), [](float value) { return value == 0; });
        if (silent) std::fill(prediction.begin(), prediction.end(), 0);
        else estimate();
        for (unsigned stem = 0; stem < 4; ++stem) {
            for (unsigned channel = 0; channel < 2; ++channel) {
                const float *source = prediction.data() + (stem * 2 + channel) * predictedFrames;
                float *tail = previousTail.data() + (stem * 2 + channel) * overlapFrames;
                for (unsigned frame = 0; frame < hop; ++frame) {
                    float value = source[frame];
                    if (hasPreviousTail && frame < overlapFrames) {
                        const float mix = float(frame) / float(overlapFrames - 1);
                        value = tail[frame] * (1 - mix) + value * mix;
                    }
                    output[(stem * hop + frame) * 2 + channel] = value;
                }
                std::copy_n(source + hop, overlapFrames, tail);
            }
        }
        hasPreviousTail = true;
        constexpr unsigned start = context - rightContext - hop;
        for (unsigned frame = 0; frame < hop; ++frame) {
            for (unsigned channel = 0; channel < 2; ++channel) {
                float named = 0;
                for (unsigned stem = 0; stem < 4; ++stem) named += output[(stem * hop + frame) * 2 + channel];
                output[(4 * hop + frame) * 2 + channel] = history[channel * context + start + frame] - named;
            }
        }
    }
};

std::atomic<bool> workerLease{false}, offlineWorkerLease{false};
struct Runtime {
    std::shared_ptr<State> state;
    const bool offlineMode;
    std::atomic<bool> cancelled{false}, finished{false};
    std::mutex messageMutex;
    std::string message;
    explicit Runtime(std::shared_ptr<State> value): state(std::move(value)), offlineMode(state->offline.load()) {}
    void fail(Fault code, const std::string &text) {
        state->setFault(code);
        { std::lock_guard<std::mutex> lock(messageMutex); message = text; }
        cancelled.store(true);
    }
    bool interrupted() { return cancelled.load(std::memory_order_relaxed) || state->fault.load() != none; }
    void run(NSURL *modelURL) {
        @autoreleasepool {
            try {
                MobileModel model(modelURL);
                if (!interrupted()) { @autoreleasepool { model.warmup(); } }
                if (!interrupted()) state->warmReady.store(true, std::memory_order_release);
                auto incoming = std::make_unique<std::array<float, hop * 2>>();
                auto separated = std::make_unique<std::array<float, hop * 10>>();
                auto pending = std::make_unique<Packet<10>>();
                std::unique_ptr<Resampler> inputResampler, outputResampler;
                uint64_t generation = 0, sequence = 0;
                unsigned filled = 0, pendingCount = 0, currentRate = 0;
                auto current = [&] { return !interrupted() && state->requestedEpoch.load() == generation; };
                auto publish = [&] {
                    const auto started = std::chrono::steady_clock::now();
                    while (current()) {
                        if (auto target = state->output.producerSlot()) {
                            target->generation = generation; target->firstFrame = pending->firstFrame;
                            target->frames = pendingCount; target->rate = currentRate;
                            std::copy_n(pending->samples.data(), pendingCount * 10, target->samples.data());
                            state->output.publish(); pendingCount = 0;
                            return true;
                        }
                        if (std::chrono::steady_clock::now() - started > std::chrono::seconds(30)) {
                            fail(backendFailure, "The CatStem output queue was not consumed."); return false;
                        }
                        std::this_thread::sleep_for(std::chrono::milliseconds(1));
                    }
                    return false;
                };
                while (!interrupted()) {
                    const auto requested = state->requestedEpoch.load();
                    if (requested != generation) {
                        generation = requested; sequence = 0; filled = 0; pendingCount = 0; currentRate = 0;
                        inputResampler.reset(); outputResampler.reset(); model.reset();
                    }
                    auto packet = state->input.consumerSlot();
                    if (!packet) { std::this_thread::sleep_for(std::chrono::milliseconds(1)); continue; }
                    if (packet->generation != generation) { state->input.consume(); continue; }
                    if (!inputResampler) {
                        currentRate = packet->rate;
                        inputResampler = std::make_unique<Resampler>(2, currentRate, modelRate);
                        outputResampler = std::make_unique<Resampler>(10, modelRate, currentRate);
                    }
                    if (packet->rate != currentRate) { fail(protocolFailure, "The audio rate changed without resetting CatStem."); break; }
                    inputResampler->feed(packet->samples.data(), packet->frames, [&](const float *frame, int64_t) {
                        if (!current()) return false;
                        (*incoming)[filled * 2] = frame[0]; (*incoming)[filled * 2 + 1] = frame[1];
                        if (++filled < hop) return true;
                        @autoreleasepool { model.process(incoming->data(), separated->data()); }
                        if (!current()) return false;
                        const int64_t firstFrame = int64_t(sequence * hop) - rightContext;
                        const unsigned skip = firstFrame < 0 ? unsigned(std::min<int64_t>(hop, -firstFrame)) : 0;
                        bool accepted = true;
                        for (unsigned f = skip; f < hop && accepted; ++f) {
                            std::array<float, 10> values{};
                            for (unsigned stem = 0; stem < stems; ++stem)
                                for (unsigned channel = 0; channel < 2; ++channel) {
                                    const float value = (*separated)[(stem * hop + f) * 2 + channel];
                                    if (!std::isfinite(value)) { fail(backendFailure, "CatStem returned nonfinite audio."); return false; }
                                    values[stem * 2 + channel] = value;
                                }
                            accepted = outputResampler->feed(values.data(), 1, [&](const float *samples, int64_t index) {
                                if (!current()) return false;
                                if (!pendingCount) pending->firstFrame = index;
                                std::copy_n(samples, 10, pending->samples.data() + pendingCount * 10);
                                return ++pendingCount < maxBlock || publish();
                            });
                        }
                        if (accepted && pendingCount) accepted = publish();
                        if (accepted) { sequence++; filled = 0; }
                        return accepted;
                    });
                    state->input.consume();
                }
            } catch (const std::exception &failure) { fail(backendFailure, failure.what()); }
        }
        state->warmReady.store(false);
        (offlineMode ? offlineWorkerLease : workerLease).store(false, std::memory_order_release);
        finished.store(true, std::memory_order_release);
    }
};
