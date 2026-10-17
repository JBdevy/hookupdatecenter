#include "MP3Writer.h"
#include "../../Core/ThirdParty/Lame/lame.h"

namespace catlive {
namespace {
void checked(int result, const char *operation) {
    if (result < 0) throw std::runtime_error(std::string(operation) + " (LAME " + std::to_string(result) + ")");
}
}
struct MP3Writer::Impl {
    lame_t encoder = nullptr;
    std::unique_ptr<FileOutputStream> output;
    std::vector<unsigned char> encoded;
    int channels = 0;
    bool finished = false;
    ~Impl() { if (encoder) lame_close(encoder); }
    void append(int count) {
        checked(count, "MP3 encoding");
        if (count && !output->write(encoded.data(), (size_t)count))
            throw std::runtime_error("Não foi possível escrever o arquivo MP3.");
    }
};
MP3Writer::MP3Writer(const File &file, int rate, int channels, int bitrate)
    : impl(std::make_unique<Impl>()) {
    if ((rate != 32000 && rate != 44100 && rate != 48000) || channels < 1 || channels > 2)
        throw std::runtime_error("Frequência ou canais MP3 inválidos.");
    auto &p = *impl;
    p.channels = channels;
    p.encoder = lame_init();
    if (!p.encoder) throw std::runtime_error("Não foi possível iniciar o encoder MP3.");
    checked(lame_set_in_samplerate(p.encoder, rate), "MP3 input rate");
    checked(lame_set_out_samplerate(p.encoder, rate), "MP3 output rate");
    checked(lame_set_num_channels(p.encoder, channels), "MP3 channels");
    checked(lame_set_mode(p.encoder, channels == 1 ? MONO : JOINT_STEREO), "MP3 channel mode");
    checked(lame_set_VBR(p.encoder, vbr_off), "MP3 constant bitrate");
    checked(lame_set_brate(p.encoder, bitrate), "MP3 bitrate");
    checked(lame_set_quality(p.encoder, 0), "MP3 quality");
    // Keep the Xing/Info frame and finalize its LAME delay/padding metadata.
    // Both platform readers can then expose the original PCM timeline.
    checked(lame_set_bWriteVbrTag(p.encoder, 1), "MP3 gapless metadata");
    lame_set_write_id3tag_automatic(p.encoder, 0);
    checked(lame_init_params(p.encoder), "MP3 initialization");
    if (lame_get_brate(p.encoder) != bitrate || lame_get_out_samplerate(p.encoder) != rate)
        throw std::runtime_error("O encoder MP3 não aceitou a frequência ou o bitrate solicitado.");
    p.output = file.createOutputStream();
    if (!p.output || !p.output->setPosition(0) || p.output->truncate().failed())
        throw std::runtime_error("Não foi possível criar o arquivo MP3.");
    p.encoded.resize(16384);
}
MP3Writer::~MP3Writer() = default;
int MP3Writer::encoderDelaySamples() const { return lame_get_encoder_delay(impl->encoder); }
void MP3Writer::write(const AudioBuffer<float> &audio, int count) {
    auto &p = *impl;
    if (p.finished || count < 0 || count > audio.getNumSamples() || audio.getNumChannels() < p.channels)
        throw std::runtime_error("Bloco de áudio MP3 inválido.");
    if (count == 0) return;
    const auto capacity = (size_t)count + (size_t)count / 4 + 7200;
    if (p.encoded.size() < capacity) p.encoded.resize(capacity);
    p.append(lame_encode_buffer_ieee_float(p.encoder, audio.getReadPointer(0),
        audio.getReadPointer(p.channels > 1 ? 1 : 0), count, p.encoded.data(), (int)p.encoded.size()));
}
void MP3Writer::finish() {
    auto &p = *impl;
    if (p.finished) return;
    p.append(lame_encode_flush(p.encoder, p.encoded.data(), (int)p.encoded.size()));
    const auto tagBytes = lame_get_lametag_frame(p.encoder, p.encoded.data(), p.encoded.size());
    if (!tagBytes || tagBytes > p.encoded.size() || !p.output->setPosition(0) ||
        !p.output->write(p.encoded.data(), tagBytes))
        throw std::runtime_error("Não foi possível concluir os metadados de alinhamento MP3.");
    p.output->flush();
    if (p.output->getStatus().failed()) throw std::runtime_error("Não foi possível concluir o arquivo MP3.");
    p.output.reset();
    p.finished = true;
}
}
