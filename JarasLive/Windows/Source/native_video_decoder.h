#pragma once

#include <chrono>
#include <cstdint>
#include <functional>
#include <memory>
#include <string>
#include <vector>

namespace vshook_video {

struct DecodedFrame {
  // Mantém o quadro publicado vivo enquanto a janela o desenha. A
  // decodificação acontece em paralelo e nunca altera este buffer.
  std::shared_ptr<const std::vector<std::uint8_t>> storage;
  const std::uint8_t* pixels = nullptr;
  int width = 0;
  int height = 0;
  int stride = 0;
  double timestamp = 0.0;
  std::uint64_t sequence = 0;
};

// Decoder de video assincrono (FFmpeg no Windows e AVFoundation no macOS).
// frameAt() sempre devolve imediatamente o ultimo quadro publicado.
class Decoder {
public:
  using FrameReadyCallback = std::function<void()>;

  explicit Decoder(FrameReadyCallback frameReady = {});
  ~Decoder();

  Decoder(const Decoder&) = delete;
  Decoder& operator=(const Decoder&) = delete;

  bool frameAt(
    const std::string& utf8Path,
    const std::string& playbackKey,
    double sourceTime,
    bool playing,
    double playbackRate,
    int requestedWidth,
    int requestedHeight,
    DecodedFrame& output);
  bool frameAt(
    const std::string& utf8Path,
    const std::string& playbackKey,
    double sourceTime,
    bool playing,
    double playbackRate,
    int requestedWidth,
    int requestedHeight,
    std::chrono::steady_clock::time_point sourceSampledAt,
    DecodedFrame& output);
  void reset();
  int status() const;

private:
  struct Impl;
  std::unique_ptr<Impl> impl_;
};

} // namespace vshook_video
