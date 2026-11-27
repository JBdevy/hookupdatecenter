// ARA document model and sample access for hosted VST3 inserts.
namespace araHost {
using namespace ARA;

constexpr auto allRoles = kARAPlaybackRendererRole | kARAEditorRendererRole | kARAEditorViewRole;
constexpr size_t archiveLimit = 64 * 1024 * 1024;
constexpr unsigned readBlockSize = 4096;

struct Media {
    NSURL *url;
    ARASampleCount frames = 0;
    ARASampleRate rate = 0;
    ARAChannelCount channels = 0;
};

struct FileReader {
    ExtAudioFileRef file = nullptr;
    Media media;
    bool wide = false;
    ARASamplePosition cursor = 0;
    std::array<std::array<float, readBlockSize>, 2> scratch{};
    explicit FileReader(const Media &media, bool wide) : media(media), wide(wide) {}
    ~FileReader() { if (file) ExtAudioFileDispose(file); }
};

ARAAudioReaderHostRef ARA_CALL createReader(ARAAudioAccessControllerHostRef, ARAAudioSourceHostRef ref, ARABool wide) {
    try {
        auto reader = std::make_unique<FileReader>(*reinterpret_cast<Media *>(ref), wide != kARAFalse);
        if (ExtAudioFileOpenURL((__bridge CFURLRef)reader->media.url, &reader->file) != noErr) return nullptr;
        AudioStreamBasicDescription format{};
        format.mSampleRate = reader->media.rate;
        format.mFormatID = kAudioFormatLinearPCM;
        format.mFormatFlags = kAudioFormatFlagsNativeFloatPacked | kAudioFormatFlagIsNonInterleaved;
        format.mBytesPerPacket = format.mBytesPerFrame = sizeof(float);
        format.mFramesPerPacket = 1;
        format.mChannelsPerFrame = reader->media.channels;
        format.mBitsPerChannel = 32;
        if (ExtAudioFileSetProperty(reader->file, kExtAudioFileProperty_ClientDataFormat, sizeof(format), &format) != noErr) return nullptr;
        return reinterpret_cast<ARAAudioReaderHostRef>(reader.release());
    } catch (...) { return nullptr; }
}

ARABool ARA_CALL readSamples(ARAAudioAccessControllerHostRef, ARAAudioReaderHostRef ref,
                            ARASamplePosition position, ARASampleCount count, void *const output[]) {
    auto &reader = *reinterpret_cast<FileReader *>(ref);
    if (count <= 0) return kARATrue;
    const auto padding = position < 0 ? -std::max(position, -count) : 0;
    const auto firstFrame = std::max<ARASamplePosition>(0, position);
    const auto available = std::min(count - padding, std::max<ARASampleCount>(0, reader.media.frames - firstFrame));
    const auto bytes = reader.wide ? sizeof(double) : sizeof(float);
    for (int channel = 0; channel < reader.media.channels; ++channel) {
        auto target = static_cast<char *>(output[channel]);
        std::memset(target, 0, size_t(padding) * bytes);
        std::memset(target + size_t(padding + available) * bytes, 0, size_t(count - padding - available) * bytes);
    }
    if (!available) return kARATrue;
    if (reader.cursor != firstFrame && ExtAudioFileSeek(reader.file, firstFrame) != noErr) return kARAFalse;
    reader.cursor = firstFrame;
    struct { UInt32 count; AudioBuffer buffer[2]; } storage{};
    auto *buffers = reinterpret_cast<AudioBufferList *>(&storage);
    buffers->mNumberBuffers = reader.media.channels;
    for (ARASampleCount done = 0; done < available;) {
        UInt32 frames = UInt32(std::min<ARASampleCount>(readBlockSize, available - done));
        const auto expected = frames;
        for (int channel = 0; channel < reader.media.channels; ++channel) {
            void *target = reader.wide ? reader.scratch[channel].data() : static_cast<float *>(output[channel]) + padding + done;
            buffers->mBuffers[channel] = {1, UInt32(frames * sizeof(float)), target};
        }
        if (ExtAudioFileRead(reader.file, &frames, buffers) != noErr || frames != expected) {
            reader.cursor = -1;
            return kARAFalse;
        }
        if (reader.wide) {
            for (int channel = 0; channel < reader.media.channels; ++channel)
                std::copy_n(reader.scratch[channel].data(), frames, static_cast<double *>(output[channel]) + padding + done);
        }
        done += frames;
        reader.cursor += frames;
    }
    return kARATrue;
}

void ARA_CALL destroyReader(ARAAudioAccessControllerHostRef, ARAAudioReaderHostRef ref) {
    delete reinterpret_cast<FileReader *>(ref);
}

const ARAAudioAccessControllerInterface audioAccess{
    ARA_IMPLEMENTED_STRUCT_SIZE(ARAAudioAccessControllerInterface, destroyAudioReader),
    createReader, readSamples, destroyReader
};

struct Archive {
    const char *format;
    NSMutableData *data;
};
ARASize ARA_CALL archiveSize(ARAArchivingControllerHostRef, ARAArchiveReaderHostRef ref) {
    return reinterpret_cast<Archive *>(ref)->data.length;
}
ARABool ARA_CALL readArchive(ARAArchivingControllerHostRef, ARAArchiveReaderHostRef ref, ARASize position, ARASize count, ARAByte output[]) {
    NSData *data = reinterpret_cast<Archive *>(ref)->data;
    if (position > data.length || count > data.length - position) return kARAFalse;
    if (count) std::memcpy(output, static_cast<const char *>(data.bytes) + position, count);
    return kARATrue;
}
ARABool ARA_CALL writeArchive(ARAArchivingControllerHostRef, ARAArchiveWriterHostRef ref, ARASize position, ARASize count, const ARAByte input[]) {
    NSMutableData *data = reinterpret_cast<Archive *>(ref)->data;
    if (position > archiveLimit || count > archiveLimit - position) return kARAFalse;
    if (position + count > data.length) data.length = position + count;
    if (count) std::memcpy(static_cast<char *>(data.mutableBytes) + position, input, count);
    return kARATrue;
}
void ARA_CALL archivingProgress(ARAArchivingControllerHostRef, float) {}
ARAPersistentID ARA_CALL documentArchiveID(ARAArchivingControllerHostRef, ARAArchiveReaderHostRef ref) {
    return reinterpret_cast<Archive *>(ref)->format;
}
const ARAArchivingControllerInterface archiving{
    ARA_IMPLEMENTED_STRUCT_SIZE(ARAArchivingControllerInterface, getDocumentArchiveID),
    archiveSize, readArchive, writeArchive, archivingProgress, archivingProgress, documentArchiveID
};

void ARA_CALL reportAssertion(ARAAssertCategory category, const void *, const char *message) {
    std::fprintf(stderr, "CatLive ARA (%d): %s\n", int(category), message ?: "");
}
ARAAssertFunction assertFunction = reportAssertion;

// The same module may host multiple editors and a separate offline renderer.
// All calls that acquire and release factories belong to the model thread.
std::map<const ARAFactory *, unsigned> &factoryUses() {
    static auto *uses = new std::map<const ARAFactory *, unsigned>();
    return *uses;
}

class Document {
    struct Clip {
        Media media;
        ARAAudioSourceRef source = nullptr;
        ARAAudioModificationRef modification = nullptr;
        ARAPlaybackRegionRef region = nullptr;
    };
    const ARAFactory &factory;
    ARADocumentControllerHostInstance host{};
    const ARADocumentControllerInstance *instance = nullptr;
    ARAMusicalContextRef context = nullptr;
    ARARegionSequenceRef track = nullptr;
    const ARAPlugInExtensionInstance *extension = nullptr;
    std::vector<std::unique_ptr<Clip>> clips;
    std::vector<ARAContentTempoEntry> tempo;
    std::vector<ARAContentBarSignature> meter;
    bool changed = false;
    NSString *archivedState;

    struct ContentReader {
        std::vector<ARAContentTempoEntry> tempo;
        std::vector<ARAContentBarSignature> meter;
    };
    static ARABool ARA_CALL contextHasContent(ARAContentAccessControllerHostRef, ARAMusicalContextHostRef, ARAContentType type) {
        return type == kARAContentTypeTempoEntries || type == kARAContentTypeBarSignatures;
    }
    static ARAContentGrade ARA_CALL contextGrade(ARAContentAccessControllerHostRef, ARAMusicalContextHostRef, ARAContentType) {
        return kARAContentGradeApproved;
    }
    static ARAContentReaderHostRef ARA_CALL readContext(ARAContentAccessControllerHostRef ref, ARAMusicalContextHostRef,
                                                      ARAContentType type, const ARAContentTimeRange *) {
        auto &host = *reinterpret_cast<Document *>(ref);
        try {
            auto reader = std::make_unique<ContentReader>();
            if (type == kARAContentTypeTempoEntries) reader->tempo = host.tempo;
            if (type == kARAContentTypeBarSignatures) reader->meter = host.meter;
            return reinterpret_cast<ARAContentReaderHostRef>(reader.release());
        } catch (...) { return nullptr; }
    }
    static ARABool ARA_CALL sourceHasContent(ARAContentAccessControllerHostRef, ARAAudioSourceHostRef, ARAContentType) { return kARAFalse; }
    static ARAContentGrade ARA_CALL sourceGrade(ARAContentAccessControllerHostRef, ARAAudioSourceHostRef, ARAContentType) {
        return kARAContentGradeInitial;
    }
    static ARAContentReaderHostRef ARA_CALL readSourceContent(ARAContentAccessControllerHostRef, ARAAudioSourceHostRef,
                                                            ARAContentType, const ARAContentTimeRange *) { return nullptr; }
    static ARAInt32 ARA_CALL eventCount(ARAContentAccessControllerHostRef, ARAContentReaderHostRef ref) {
        const auto &reader = *reinterpret_cast<ContentReader *>(ref);
        return ARAInt32(reader.tempo.size() + reader.meter.size());
    }
    static const void *ARA_CALL event(ARAContentAccessControllerHostRef, ARAContentReaderHostRef ref, ARAInt32 index) {
        const auto &reader = *reinterpret_cast<ContentReader *>(ref);
        if (index < 0) return nullptr;
        if (size_t(index) < reader.tempo.size()) return &reader.tempo[index];
        if (size_t(index) < reader.meter.size()) return &reader.meter[index];
        return nullptr;
    }
    static void ARA_CALL closeContent(ARAContentAccessControllerHostRef, ARAContentReaderHostRef ref) {
        delete reinterpret_cast<ContentReader *>(ref);
    }
    constexpr static ARAContentAccessControllerInterface content{
        ARA_IMPLEMENTED_STRUCT_SIZE(ARAContentAccessControllerInterface, destroyContentReader),
        contextHasContent, contextGrade, readContext, sourceHasContent, sourceGrade, readSourceContent,
        eventCount, event, closeContent
    };

    void readTempo(NSArray<NSDictionary *> *sections) {
        double bpm = 120;
        tempo.push_back({0, 0});
        meter.push_back({4, 4, 0});
        for (NSDictionary *section in sections) {
            const double start = [section[@"start"] doubleValue];
            const double nextBPM = [section[@"bpm"] doubleValue];
            const int beats = [section[@"beats"] intValue];
            const int unit = [section[@"unit"] intValue];
            if (!std::isfinite(start) || !std::isfinite(nextBPM) || nextBPM <= 0 ||
                start < tempo.back().timePosition || beats <= 0 || unit <= 0) continue;
            const double position = tempo.back().quarterPosition + (start - tempo.back().timePosition) * bpm / 60.0;
            if (start > tempo.back().timePosition && nextBPM != bpm) tempo.push_back({start, position});
            bpm = nextBPM;
            if (start == 0) meter.back() = {beats, unit, 0};
            else if (beats != meter.back().numerator || unit != meter.back().denominator)
                meter.push_back({beats, unit, position});
        }
        tempo.push_back({tempo.back().timePosition + 1, tempo.back().quarterPosition + bpm / 60.0});
    }

    static void ARA_CALL analysisProgress(ARAModelUpdateControllerHostRef, ARAAudioSourceHostRef, ARAAnalysisProgressState, float) {}
    static void ARA_CALL sourceUpdated(ARAModelUpdateControllerHostRef, ARAAudioSourceHostRef, const ARAContentTimeRange *, ARAContentUpdateFlags) {}
    static void ARA_CALL modificationUpdated(ARAModelUpdateControllerHostRef ref, ARAAudioModificationHostRef, const ARAContentTimeRange *, ARAContentUpdateFlags flags) {
        if (!(flags & kARAContentUpdateSignalScopeRemainsUnchanged)) reinterpret_cast<Document *>(ref)->changed = true;
    }
    static void ARA_CALL regionUpdated(ARAModelUpdateControllerHostRef, ARAPlaybackRegionHostRef, const ARAContentTimeRange *, ARAContentUpdateFlags) {}
    static void ARA_CALL documentUpdated(ARAModelUpdateControllerHostRef ref) { reinterpret_cast<Document *>(ref)->changed = true; }
    constexpr static ARAModelUpdateControllerInterface updates{
        ARA_IMPLEMENTED_STRUCT_SIZE(ARAModelUpdateControllerInterface, notifyDocumentDataChanged),
        analysisProgress, sourceUpdated, modificationUpdated, regionUpdated, documentUpdated
    };

    const ARADocumentControllerInterface &api() const { return *instance->documentControllerInterface; }
    ARADocumentControllerRef ref() const { return instance->documentControllerRef; }

    bool addClip(NSDictionary *spec) {
        auto clip = std::make_unique<Clip>();
        clip->media.url = [NSURL fileURLWithPath:spec[@"file"]];
        ExtAudioFileRef file = nullptr;
        if (ExtAudioFileOpenURL((__bridge CFURLRef)clip->media.url, &file) != noErr) return false;
        AudioStreamBasicDescription format{};
        UInt32 size = sizeof(format);
        const bool validFormat = ExtAudioFileGetProperty(file, kExtAudioFileProperty_FileDataFormat, &size, &format) == noErr;
        size = sizeof(clip->media.frames);
        const bool validLength = ExtAudioFileGetProperty(file, kExtAudioFileProperty_FileLengthFrames, &size, &clip->media.frames) == noErr;
        ExtAudioFileDispose(file);
        if (!validFormat || !validLength || clip->media.frames <= 0 || !std::isfinite(format.mSampleRate) ||
            format.mSampleRate <= 0 || format.mChannelsPerFrame < 1 || format.mChannelsPerFrame > 2) return false;
        clip->media.channels = format.mChannelsPerFrame;
        clip->media.rate = format.mSampleRate;
        NSString *name = spec[@"name"];
        NSString *identifier = spec[@"id"];
        NSString *sourceID = [identifier stringByAppendingFormat:@"/%@", spec[@"path"]];
        const double start = [spec[@"start"] doubleValue];
        const double length = [spec[@"duration"] doubleValue];
        const double offset = [spec[@"offset"] doubleValue];
        const double rate = [spec[@"rate"] doubleValue];
        if (!(std::isfinite(start) && std::isfinite(length) && std::isfinite(offset) && std::isfinite(rate)) ||
            start < 0 || length <= 0 || offset < 0 || rate <= 0) return false;
        const bool stretched = std::abs(rate - 1) > 0.000001;
        if (stretched && !(factory.supportedPlaybackTransformationFlags & kARAPlaybackTransformationTimestretch)) return false;
        const auto transformation = stretched ? kARAPlaybackTransformationTimestretch : kARAPlaybackTransformationNoChanges;
        const ARAAudioSourceProperties sourceProperties{
            ARA_IMPLEMENTED_STRUCT_SIZE(ARAAudioSourceProperties, merits64BitSamples), name.UTF8String, sourceID.UTF8String,
            clip->media.frames, clip->media.rate, clip->media.channels, kARAFalse
        };
        const ARAAudioModificationProperties modificationProperties{
            ARA_IMPLEMENTED_STRUCT_SIZE(ARAAudioModificationProperties, persistentID), name.UTF8String, identifier.UTF8String
        };
        const ARAPlaybackRegionProperties regionProperties{
            ARA_IMPLEMENTED_STRUCT_SIZE(ARAPlaybackRegionProperties, color), transformation, offset, length * (stretched ? rate : 1),
            start, length, nullptr, track, name.UTF8String, nullptr
        };
        auto *item = clip.get();
        clips.push_back(std::move(clip));
        item->source = api().createAudioSource(ref(), reinterpret_cast<ARAAudioSourceHostRef>(&item->media), &sourceProperties);
        if (!item->source) return false;
        item->modification = api().createAudioModification(ref(), item->source,
            reinterpret_cast<ARAAudioModificationHostRef>(item), &modificationProperties);
        if (!item->modification) return false;
        item->region = api().createPlaybackRegion(ref(), item->modification,
            reinterpret_cast<ARAPlaybackRegionHostRef>(item), &regionProperties);
        return item->region != nullptr;
    }

public:
    bool coversTrack = false;
    explicit Document(const ARAFactory &factory) : factory(factory) {
        auto &count = factoryUses()[&factory];
        if (count++ == 0) {
            const ARAInterfaceConfiguration configuration{
                ARA_IMPLEMENTED_STRUCT_SIZE(ARAInterfaceConfiguration, assertFunctionAddress),
                std::min<ARAAPIGeneration>(factory.highestSupportedApiGeneration, kARAAPIGeneration_2_3_Final), &assertFunction
            };
            factory.initializeARAWithConfiguration(&configuration);
        }
    }
    ~Document() {
        // The component owning the extension is stopped and destroyed first.
        if (instance) {
            // Destroying an ARA source already ends sample access. Disabling
            // each source first would separately wait for its active readers
            // before the plug-in can process the batched document teardown.
            api().beginEditing(ref());
            for (const auto &clip : clips) {
                if (clip->region) api().destroyPlaybackRegion(ref(), clip->region);
                if (clip->modification) api().destroyAudioModification(ref(), clip->modification);
                if (clip->source) api().destroyAudioSource(ref(), clip->source);
            }
            if (track) api().destroyRegionSequence(ref(), track);
            if (context) api().destroyMusicalContext(ref(), context);
            api().endEditing(ref());
            api().destroyDocumentController(ref());
        }
        auto &uses = factoryUses();
        if (--uses.at(&factory) == 0) { factory.uninitializeARA(); uses.erase(&factory); }
    }

    template<class Bind> void load(Bind bind, NSDictionary *timeline, NSString *state) {
        readTempo(timeline[@"tempo"]);
        host = {
            ARA_IMPLEMENTED_STRUCT_SIZE(ARADocumentControllerHostInstance, playbackControllerInterface),
            reinterpret_cast<ARAAudioAccessControllerHostRef>(this), &audioAccess,
            reinterpret_cast<ARAArchivingControllerHostRef>(this), &archiving,
            reinterpret_cast<ARAContentAccessControllerHostRef>(this), &content,
            reinterpret_cast<ARAModelUpdateControllerHostRef>(this), &updates, nullptr, nullptr
        };
        NSString *name = timeline[@"name"];
        const ARADocumentProperties properties{ARA_IMPLEMENTED_STRUCT_SIZE(ARADocumentProperties, name), name.UTF8String};
        instance = factory.createDocumentControllerWithDocument(&host, &properties);
        if (!instance) throw std::runtime_error("Could not open the ARA document.");

        api().beginEditing(ref());
        const ARAMusicalContextProperties contextProperties{
            ARA_IMPLEMENTED_STRUCT_SIZE(ARAMusicalContextProperties, color), name.UTF8String, 0, nullptr
        };
        context = api().createMusicalContext(ref(), reinterpret_cast<ARAMusicalContextHostRef>(this), &contextProperties);
        const ARARegionSequenceProperties trackProperties{
            ARA_IMPLEMENTED_STRUCT_SIZE(ARARegionSequenceProperties, color), name.UTF8String, 0, context, nullptr
        };
        if (context) track = api().createRegionSequence(ref(), reinterpret_cast<ARARegionSequenceHostRef>(this), &trackProperties);
        coversTrack = track && [timeline[@"playbackCompatible"] boolValue];
        @try {
            if (track) {
                for (NSDictionary *item in timeline[@"clips"])
                    if (!addClip(item)) coversTrack = false;
                if (state.length) {
                    Archive archive{factory.documentArchiveID, [[NSMutableData alloc] initWithBase64EncodedString:state options:0]};
                    if (!archive.data.length || archive.data.length > archiveLimit ||
                        !api().restoreObjectsFromArchive(ref(), reinterpret_cast<ARAArchiveReaderHostRef>(&archive), nullptr))
                        throw std::runtime_error("Could not restore the saved ARA edits.");
                    archivedState = [state copy];
                }
            }
        } @finally {
            api().endEditing(ref());
        }
        if (!track) throw std::runtime_error("Could not create the ARA track.");
        extension = bind(ref());
        if (!extension || !extension->playbackRendererInterface || !extension->editorRendererInterface || !extension->editorViewInterface)
            throw std::runtime_error("The plugin did not provide the requested ARA2 interfaces.");
        extension->editorRendererInterface->addRegionSequence(extension->editorRendererRef, track);
        for (const auto &clip : clips) {
            if (!clip->region) continue;
            extension->playbackRendererInterface->addPlaybackRegion(extension->playbackRendererRef, clip->region);
            api().enableAudioSourceSamplesAccess(ref(), clip->source, kARATrue);
        }
    }

    void selectTrack() const {
        const ARAViewSelection selection{
            ARA_IMPLEMENTED_STRUCT_SIZE(ARAViewSelection, timeRange), 0, nullptr, 1, &track, nullptr
        };
        extension->editorViewInterface->notifySelection(extension->editorViewRef, &selection);
    }
    bool poll() { api().notifyModelUpdates(ref()); return changed; }
    NSString *state() {
        api().notifyModelUpdates(ref());
        if (!changed && archivedState) return archivedState;
        if (!changed) return @"";
        Archive archive{factory.documentArchiveID, [NSMutableData data]};
        if (!api().storeObjectsToArchive(ref(), reinterpret_cast<ARAArchiveWriterHostRef>(&archive), nullptr) || !archive.data.length)
            return nil;
        archivedState = [archive.data base64EncodedStringWithOptions:0];
        changed = false;
        return archivedState;
    }
};

std::unique_ptr<Document> bind(FUnknown *component, NSDictionary *timeline, NSString *state) {
    if (!timeline || !NSThread.isMainThread) return nullptr;
    auto factoryEntry = query<IPlugInEntryPoint>(component);
    if (!factoryEntry) return nullptr;
    const auto *factory = factoryEntry->getFactory();
    factoryEntry->release();
    if (!factory || factory->highestSupportedApiGeneration < kARAAPIGeneration_2_0_Final ||
        factory->lowestSupportedApiGeneration > kARAAPIGeneration_2_3_Final) return nullptr;
    auto roles = query<IPlugInEntryPoint2>(component);
    if (!roles) return nullptr;
    const std::shared_ptr<IPlugInEntryPoint2> entry(roles, [](auto *value) { value->release(); });
    auto document = std::make_unique<Document>(*factory);
    document->load([&](auto controller) {
        return entry->bindToDocumentControllerWithRoles(controller, allRoles, allRoles);
    }, timeline, state);
    return document;
}

std::unique_ptr<Document> bind(AudioUnit component, NSDictionary *timeline, NSString *state) {
    if (!component || !timeline || !NSThread.isMainThread) return nullptr;
    ARAAudioUnitFactory query{kARAAudioUnitMagic, nullptr};
    UInt32 size = sizeof(query);
    if (AudioUnitGetProperty(component, kAudioUnitProperty_ARAFactory, kAudioUnitScope_Global, 0, &query, &size) != noErr ||
        size != sizeof(query) || query.inOutMagicNumber != kARAAudioUnitMagic) return nullptr;
    const auto *factory = query.outFactory;
    if (!factory || factory->highestSupportedApiGeneration < kARAAPIGeneration_2_0_Final ||
        factory->lowestSupportedApiGeneration > kARAAPIGeneration_2_3_Final) return nullptr;
    auto document = std::make_unique<Document>(*factory);
    document->load([&](auto controller) -> const ARAPlugInExtensionInstance * {
        ARAAudioUnitPlugInExtensionBinding request{kARAAudioUnitMagic, controller, nullptr, allRoles, allRoles};
        UInt32 length = sizeof(request);
        if (AudioUnitGetProperty(component, kAudioUnitProperty_ARAPlugInExtensionBindingWithRoles, kAudioUnitScope_Global, 0,
                                 &request, &length) != noErr || length != sizeof(request) ||
            request.inOutMagicNumber != kARAAudioUnitMagic) return nullptr;
        return request.outPlugInExtension;
    }, timeline, state);
    return document;
}
}
