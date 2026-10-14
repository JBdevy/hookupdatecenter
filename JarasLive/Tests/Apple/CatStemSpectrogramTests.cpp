#include "../../Apple/Bridge/CatStemSpectrogram.hpp"
#include <fstream>
#include <iostream>
#include <string>

static std::vector<float> read(const std::string& path, size_t count) {
    std::ifstream stream(path, std::ios::binary);
    std::vector<float> data(count);
    if (!stream.read(reinterpret_cast<char*>(data.data()), count * sizeof(float)))
        throw std::runtime_error("Missing spectral fixture: " + path);
    return data;
}
static void compare(const std::vector<float>& actual, const std::vector<float>& expected, float tolerance, const char *name) {
    float maximum = 0;
    double squared = 0;
    for (size_t i = 0; i < actual.size(); ++i) {
        if (!std::isfinite(actual[i])) throw std::runtime_error("Nonfinite spectral sample");
        const float difference = std::abs(actual[i] - expected[i]);
        maximum = std::max(maximum, difference); squared += difference * difference;
    }
    std::cout << name << " maximum=" << maximum << " rms=" << std::sqrt(squared / actual.size()) << std::endl;
    if (maximum > tolerance) throw std::runtime_error(std::string(name) + " differs from PyTorch");
}
int main(int argc, char **argv) {
    if (argc != 2) return 2;
    using CatStemMobile::Spectrogram;
    const std::string directory = argv[1];
    Spectrogram transform;
    const auto input = read(directory + "/input.f32", 2 * Spectrogram::context);
    const auto spectrum = read(directory + "/spectrum.f32", Spectrogram::values);
    const auto reconstructed = read(directory + "/reconstructed.f32", 2 * Spectrogram::context);
    const auto predicted = read(directory + "/predicted.f32", Spectrogram::values);
    const auto predictionAudio = read(directory + "/prediction-audio.f32", 2 * Spectrogram::context);
    std::vector<float> actual(Spectrogram::values), output(2 * Spectrogram::context);
    transform.encode(input.data(), actual.data());
    compare(actual, spectrum, 0.00001f, "STFT");
    transform.decode(spectrum.data(), output.data());
    compare(output, reconstructed, 0.00001f, "ISTFT");
    transform.decode(predicted.data(), output.data());
    compare(output, predictionAudio, 0.00001f, "Predicted ISTFT");
    std::cout << "CatStem Core ML spectral boundary PASS" << std::endl;
}
