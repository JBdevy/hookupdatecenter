// ARA document lifecycle for the Windows VST3 host. Each sample reader owns
// its decoder and is called on the plug-in's analysis threads.
namespace araHost {
using namespace ARA;

constexpr auto allRoles = kARAPlaybackRendererRole | kARAEditorRendererRole | kARAEditorViewRole;
constexpr std::size_t archiveLimit = 64 * 1024 * 1024;

struct Media {
    std::filesystem::path file;
    AudioFileInfo info;
};
struct Reader {
    AudioFile file;
    bool wide;
    std::array<std::array<float, 4096>, 2> scratch{};
    Reader(const Media &media, bool wide) : file(media.file), wide(wide) {}
};

ARAAudioReaderHostRef ARA_CALL createReader(ARAAudioAccessControllerHostRef, ARAAudioSourceHostRef ref, ARABool wide) {
    try {
        auto reader = std::make_unique<Reader>(*reinterpret_cast<Media *>(ref), wide != kARAFalse);
        return reinterpret_cast<ARAAudioReaderHostRef>(reader.release());
    } catch (...) { return nullptr; }
}

ARABool ARA_CALL readSamples(ARAAudioAccessControllerHostRef, ARAAudioReaderHostRef ref,
                            ARASamplePosition position, ARASampleCount count, void *const output[]) {
    if (count <= 0) return kARATrue;
    auto &reader = *reinterpret_cast<Reader *>(ref);
    const auto &info = reader.file.info();
    const auto padding = position < 0 ? -std::max(position, -count) : 0;
    const auto firstFrame = std::max<ARASamplePosition>(0, position);
    const auto available = std::min(count - padding, std::max<ARASampleCount>(0, ARASampleCount(info.frameCount) - firstFrame));
    const auto bytes = reader.wide ? sizeof(double) : sizeof(float);
    if (std::uint64_t(count) > std::numeric_limits<std::size_t>::max() / bytes) return kARAFalse;
    for (unsigned ch = 0; ch < info.channels; ++ch) {
        auto *target = static_cast<char *>(output[ch]);
        if (!target) return kARAFalse;
        std::memset(target, 0, std::size_t(padding) * bytes);
        std::memset(target + std::size_t(padding + available) * bytes, 0, std::size_t(count - padding - available) * bytes);
    }
    try {
        for (ARASampleCount done = 0; done < available;) {
            const auto frames = std::size_t(std::min<ARASampleCount>(reader.scratch[0].size(), available - done));
            float *planes[2]{};
            for (unsigned ch = 0; ch < info.channels; ++ch)
                planes[ch] = reader.wide ? reader.scratch[ch].data() : static_cast<float *>(output[ch]) + padding + done;
            if (reader.file.readFrames(firstFrame + done, planes, info.channels, frames) != frames) return kARAFalse;
            if (reader.wide) for (unsigned ch = 0; ch < info.channels; ++ch)
                std::copy_n(planes[ch], frames, static_cast<double *>(output[ch]) + padding + done);
            done += frames;
        }
    } catch (...) { return kARAFalse; }
    return kARATrue;
}

void ARA_CALL destroyReader(ARAAudioAccessControllerHostRef, ARAAudioReaderHostRef ref) {
    delete reinterpret_cast<Reader *>(ref);
}
const ARAAudioAccessControllerInterface audioAccess{
    ARA_IMPLEMENTED_STRUCT_SIZE(ARAAudioAccessControllerInterface, destroyAudioReader),
    createReader, readSamples, destroyReader
};

struct Archive {
    const char *format;
    std::vector<std::uint8_t> data;
};
ARASize ARA_CALL archiveSize(ARAArchivingControllerHostRef, ARAArchiveReaderHostRef ref) {
    return reinterpret_cast<Archive *>(ref)->data.size();
}
ARABool ARA_CALL readArchive(ARAArchivingControllerHostRef, ARAArchiveReaderHostRef ref, ARASize position, ARASize count, ARAByte output[]) {
    const auto &data = reinterpret_cast<Archive *>(ref)->data;
    if (position > data.size() || count > data.size() - position) return kARAFalse;
    if (count) std::memcpy(output, data.data() + position, count);
    return kARATrue;
}
ARABool ARA_CALL writeArchive(ARAArchivingControllerHostRef, ARAArchiveWriterHostRef ref, ARASize position, ARASize count, const ARAByte input[]) {
    auto &data = reinterpret_cast<Archive *>(ref)->data;
    if (position > archiveLimit || count > archiveLimit - position) return kARAFalse;
    try {
        if (position + count > data.size()) data.resize(std::size_t(position + count));
        if (count) std::memcpy(data.data() + position, input, count);
        return kARATrue;
    } catch (...) { return kARAFalse; }
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
    std::fprintf(stderr, "CatLive ARA (%d): %s\n", int(category), message ? message : "");
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
    std::vector<std::uint8_t> archivedState;

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

    void readTempo(const std::vector<jaras::PluginTempoMap::Point> &sections) {
        double bpm = 120;
        tempo.push_back({0, 0});
        meter.push_back({4, 4, 0});
        for (const auto &section : sections) {
            const double start = section.seconds, nextBPM = section.bpm;
            const int beats = section.beats, unit = section.unit;
            if (!std::isfinite(start) || !std::isfinite(nextBPM) || nextBPM <= 0 ||
                start < tempo.back().timePosition || beats <= 0 || unit <= 0) continue;
            const double position = tempo.back().quarterPosition + (start - tempo.back().timePosition) * bpm / 60.0;
            if (start > tempo.back().timePosition) tempo.push_back({start, position});
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

    bool addClip(const ARAClip &spec) {
        auto clip = std::make_unique<Clip>();
        try { clip->media = {spec.file, AudioFile::inspect(spec.file)}; }
        catch (const std::exception &) { return false; }
        const auto &info = clip->media.info;
        if (info.frameCount == 0 || info.channels == 0 || info.channels > 2) return false;
        const auto sourceID = spec.id + "/" + spec.sourcePath;
        const double start = spec.start, length = spec.duration, offset = spec.offset, rate = spec.rate;
        if (!(std::isfinite(start) && std::isfinite(length) && std::isfinite(offset) && std::isfinite(rate)) ||
            start < 0 || length <= 0 || offset < 0 || rate <= 0) return false;
        const bool stretched = std::abs(rate - 1) > 0.000001;
        if (stretched && !(factory.supportedPlaybackTransformationFlags & kARAPlaybackTransformationTimestretch)) return false;
        const auto transformation = stretched ? kARAPlaybackTransformationTimestretch : kARAPlaybackTransformationNoChanges;
        const ARAAudioSourceProperties sourceProperties{
            ARA_IMPLEMENTED_STRUCT_SIZE(ARAAudioSourceProperties, merits64BitSamples), spec.name.c_str(), sourceID.c_str(),
            ARASampleCount(info.frameCount), double(info.sampleRate), ARAChannelCount(info.channels), kARAFalse
        };
        const ARAAudioModificationProperties modificationProperties{
            ARA_IMPLEMENTED_STRUCT_SIZE(ARAAudioModificationProperties, persistentID), spec.name.c_str(), spec.id.c_str()
        };
        const ARAPlaybackRegionProperties regionProperties{
            ARA_IMPLEMENTED_STRUCT_SIZE(ARAPlaybackRegionProperties, color), transformation, offset, length * (stretched ? rate : 1),
            start, length, nullptr, track, spec.name.c_str(), nullptr
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

    template<class Bind> void load(Bind bind, const ARATimeline &timeline, const std::vector<std::uint8_t> &state) {
        readTempo(timeline.tempo);
        host = {
            ARA_IMPLEMENTED_STRUCT_SIZE(ARADocumentControllerHostInstance, playbackControllerInterface),
            reinterpret_cast<ARAAudioAccessControllerHostRef>(this), &audioAccess,
            reinterpret_cast<ARAArchivingControllerHostRef>(this), &archiving,
            reinterpret_cast<ARAContentAccessControllerHostRef>(this), &content,
            reinterpret_cast<ARAModelUpdateControllerHostRef>(this), &updates, nullptr, nullptr
        };
        const auto *name = timeline.name.c_str();
        const ARADocumentProperties properties{ARA_IMPLEMENTED_STRUCT_SIZE(ARADocumentProperties, name), name};
        instance = factory.createDocumentControllerWithDocument(&host, &properties);
        if (!instance) throw std::runtime_error("Could not open the ARA document.");

        api().beginEditing(ref());
        const ARAMusicalContextProperties contextProperties{
            ARA_IMPLEMENTED_STRUCT_SIZE(ARAMusicalContextProperties, color), name, 0, nullptr
        };
        context = api().createMusicalContext(ref(), reinterpret_cast<ARAMusicalContextHostRef>(this), &contextProperties);
        const ARARegionSequenceProperties trackProperties{
            ARA_IMPLEMENTED_STRUCT_SIZE(ARARegionSequenceProperties, color), name, 0, context, nullptr
        };
        if (context) track = api().createRegionSequence(ref(), reinterpret_cast<ARARegionSequenceHostRef>(this), &trackProperties);
        coversTrack = track && timeline.rendersTrack;
        try {
            if (track) {
                for (const auto &item : timeline.clips)
                    if (!addClip(item)) coversTrack = false;
                coversTrack = coversTrack && !clips.empty();
                if (!state.empty()) {
                    Archive archive{factory.documentArchiveID, state};
                    if (archive.data.size() > archiveLimit ||
                        !api().restoreObjectsFromArchive(ref(), reinterpret_cast<ARAArchiveReaderHostRef>(&archive), nullptr))
                        throw std::runtime_error("Could not restore the saved ARA edits.");
                    archivedState = state;
                }
            }
        } catch (...) {
            api().endEditing(ref());
            throw;
        }
        api().endEditing(ref());
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
    const std::vector<std::uint8_t> &state() {
        api().notifyModelUpdates(ref());
        if (!changed) return archivedState;
        Archive archive{factory.documentArchiveID, {}};
        if (!api().storeObjectsToArchive(ref(), reinterpret_cast<ARAArchiveWriterHostRef>(&archive), nullptr) || archive.data.empty())
            throw std::runtime_error("Could not save the ARA edits.");
        archivedState = std::move(archive.data);
        changed = false;
        return archivedState;
    }
};

std::unique_ptr<Document> bind(FUnknown *component, const ARATimeline *timeline,
                               const std::vector<std::uint8_t> &state) {
    if (!timeline) return nullptr;
    auto *factoryEntry = query<IPlugInEntryPoint>(component);
    if (!factoryEntry) return nullptr;
    const auto *factory = factoryEntry->getFactory();
    factoryEntry->release();
    if (!factory || factory->highestSupportedApiGeneration < kARAAPIGeneration_2_0_Final ||
        factory->lowestSupportedApiGeneration > kARAAPIGeneration_2_3_Final) return nullptr;
    auto *roles = query<IPlugInEntryPoint2>(component);
    if (!roles) return nullptr;
    const std::shared_ptr<IPlugInEntryPoint2> entry(roles, [](auto *value) { value->release(); });
    auto document = std::make_unique<Document>(*factory);
    document->load([&](auto controller) {
        return entry->bindToDocumentControllerWithRoles(controller, allRoles, allRoles);
    }, *timeline, state);
    return document;
}
}
