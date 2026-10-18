#pragma once
#include "MediaSource.h"

namespace catlive::externalMedia {
inline bool supported(const File &file) {
    return file.hasFileExtension("wav;wave;aif;aiff;flac;mp3;ogg;m4a;aac;mp4;mov;m4v;avi;mkv;webm;wmv;png;jpg;jpeg;bmp;gif;tif;tiff");
}
struct Preview {
    File file;
    std::optional<double> duration;
};
// Like GridExternalMedia on macOS, read only metadata during a drag. Never
// decode samples, create peaks or copy the source until the user drops it.
inline std::optional<double> duration(const File &file) {
    try {
        if (file.hasFileExtension("png;jpg;jpeg;bmp;gif;tif;tiff")) return 10.;
        double seconds = 0;
        if (file.hasFileExtension("mp4;mov;m4v;avi;mkv;webm;wmv"))
            seconds = inspectMediaSource(file).duration;
        else {
            AudioFormatManager formats;
            registerAudioFormats(formats);
            std::unique_ptr<AudioFormatReader> reader(formats.createReaderFor(file));
            if (reader && reader->sampleRate > 0) seconds = reader->lengthInSamples / reader->sampleRate;
        }
        if (std::isfinite(seconds) && seconds > 0) return seconds;
    } catch (...) {}
    return {};
}
}
