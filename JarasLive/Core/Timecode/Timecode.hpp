#pragma once

#include <algorithm>
#include <array>
#include <cmath>
#include <cstdint>

namespace jaras {

struct NativeMtcFrameRate {
  double framesPerSecond = 30.0;
  int nominalRate = 30;
  int rateCode = 3;
  bool dropFrame = false;
};

// MTC has only four rate codes. HFR video projects use their corresponding
// half-rate clock; counting 60 frames and labelling them 30 doubles the time.
// Fractional non-drop rates retain their pulldown, not a forced DF numbering.
inline NativeMtcFrameRate nativeMtcFrameRate(double rawRate, bool dropFrame)
{
  NativeMtcFrameRate rate;
  if (!std::isfinite(rawRate) || rawRate < 20.0 || rawRate > 61.0) {
    return rate;
  }
  if (rawRate >= 47.0) rawRate /= 2.0;
  const auto nearRate = [rawRate](double expected) {
    return std::fabs(rawRate - expected) < 0.01;
  };
  if (nearRate(24.0) || nearRate(24000.0 / 1001.0)) {
    rate.framesPerSecond = nearRate(24.0) ? 24.0 : 24000.0 / 1001.0;
    rate.nominalRate = 24;
    rate.rateCode = 0;
  } else if (nearRate(25.0)) {
    rate.framesPerSecond = 25.0;
    rate.nominalRate = 25;
    rate.rateCode = 1;
  } else if (nearRate(30.0) || nearRate(30000.0 / 1001.0)) {
    rate.framesPerSecond = dropFrame || !nearRate(30.0)
      ? 30000.0 / 1001.0 : 30.0;
    rate.dropFrame = dropFrame;
    rate.rateCode = dropFrame ? 2 : 3;
  }
  return rate;
}

struct NativeMtcTimeFields {
  int hour = 0;
  int minute = 0;
  int second = 0;
  int frame = 0;
  int rateCode = 3;
};

inline NativeMtcTimeFields nativeMtcTimeFields(double rawSeconds,
  double rawFrameRate, bool dropFrame, bool roundToNearestFrame = false)
{
  NativeMtcTimeFields fields;
  const NativeMtcFrameRate rate = nativeMtcFrameRate(rawFrameRate, dropFrame);
  fields.rateCode = rate.rateCode;
  const double seconds = std::isfinite(rawSeconds)
    ? std::max(0.0, rawSeconds) : 0.0;
  const int64_t framesPerDay = rate.dropFrame ? 2589408
    : static_cast<int64_t>(rate.nominalRate) * 60 * 60 * 24;
  // Reduce before converting to an integer, including malformed huge inputs.
  const double daySeconds = framesPerDay / rate.framesPerSecond;
  const double exactFrame = std::fmod(seconds, daySeconds) * rate.framesPerSecond;
  // Playback must not run ahead. A stopped locate represents the nearest
  // cursor frame, including 469.999999 -> 00:07:50:00 at 30 FPS.
  int64_t frameNumber = roundToNearestFrame
    ? static_cast<int64_t>(std::llround(exactFrame))
    : static_cast<int64_t>(std::floor(exactFrame + 0.000001));
  frameNumber %= framesPerDay;
  if (rate.dropFrame) {
    const int64_t tenMinuteBlocks = frameNumber / 17982;
    const int64_t remainder = frameNumber % 17982;
    frameNumber += 18 * tenMinuteBlocks;
    if (remainder >= 2) frameNumber += 2 * ((remainder - 2) / 1798);
  }
  fields.frame = static_cast<int>(frameNumber % rate.nominalRate);
  const int64_t totalSeconds = frameNumber / rate.nominalRate;
  fields.second = static_cast<int>(totalSeconds % 60);
  fields.minute = static_cast<int>((totalSeconds / 60) % 60);
  fields.hour = static_cast<int>((totalSeconds / 3600) % 24);
  return fields;
}

inline int nativeMtcQuarterFrameData(const NativeMtcTimeFields& fields,
  int quarterFrameIndex)
{
  const int index = quarterFrameIndex & 7;
  int nibble = 0;
  switch (index) {
    case 0: nibble = fields.frame & 0x0f; break;
    case 1: nibble = (fields.frame >> 4) & 0x01; break;
    case 2: nibble = fields.second & 0x0f; break;
    case 3: nibble = (fields.second >> 4) & 0x03; break;
    case 4: nibble = fields.minute & 0x0f; break;
    case 5: nibble = (fields.minute >> 4) & 0x03; break;
    case 6: nibble = fields.hour & 0x0f; break;
    case 7:
      nibble = ((fields.hour >> 4) & 0x01) | ((fields.rateCode & 0x03) << 1);
      break;
  }
  return (index << 4) | nibble;
}

} // namespace jaras

namespace jaras {
// SMPTE 12M: BCD time fields, biphase correction, then the 16-bit sync word.
inline std::array<bool,80> ltcFrame(double seconds, double fps) {
    const auto fields = nativeMtcTimeFields(seconds, fps, fps == 29.97);
    std::array<bool,80> bits{};
    auto field = [&](int start,int count,int value) { for(int b=0;b<count;++b) bits[start+b]=(value>>b)&1; };
    field(0,4,fields.frame%10); field(8,2,fields.frame/10);
    bits[10]=fps==29.97;
    field(16,4,fields.second%10); field(24,3,fields.second/10);
    field(32,4,fields.minute%10); field(40,3,fields.minute/10);
    field(48,4,fields.hour%10); field(56,2,fields.hour/10);
    field(64,16,0xbffc);
    bool parity=false; for(bool bit:bits) parity ^= bit;
    bits[fps==25 ? 59 : 27]=parity;
    return bits;
}
}
