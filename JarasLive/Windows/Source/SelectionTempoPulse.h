#pragma once

#include <algorithm>
#include <atomic>
#include <cstdint>
#include <string>
#include <utility>
#include <cmath>
#include <optional>
#include <vector>

namespace catlive::selectionTempo {
constexpr int envelopeHz = 1000;
struct Estimate { double bpm, weight; };

using Range = std::pair<double, double>;
struct Span {
    std::string path;
    double start, end, source, rate, loopStart, loopLength;
    double sourceAt(double time) const {
        const double raw = source + (time - start) * rate;
        return loopLength > 0 && raw >= loopStart ? loopStart + std::fmod(raw-loopStart, loopLength) : raw;
    }
};
struct Lane { bool click; std::vector<Span> spans; };

// Distribute analysis over occupied time, even for projects with hours of
// empty grid between clips. Retain small gaps between individual drum hits.
inline std::vector<Range> windows(const Lane& lane) {
    std::vector<Range> coverage;
    for (const auto& s : lane.spans) coverage.emplace_back(s.start,s.end);
    std::sort(coverage.begin(),coverage.end());
    std::vector<Range> merged;
    for (const auto& r : coverage) {
        if (merged.empty() || r.first > merged.back().second + 1.) merged.push_back(r);
        else merged.back().second = std::max(merged.back().second,r.second);
    }
    double total = 0;
    for (const auto& r : merged) total += r.second - r.first;
    const int count = total <= 12 ? 1 : total <= 24 ? 2 : 3;
    std::vector<Range> result;
    for (int i = 0; i < count; ++i) {
        double at = total * (i + .5) / count;
        for (const auto& r : merged) {
            const double length = r.second - r.first;
            if (at > length) { at -= length; continue; }
            const double width = std::min({12.,length,total/count});
            const double start = std::clamp(r.first + at - width/2,r.first,std::max(r.first,r.second-width));
            Range sample{start,start+width};
            if (result.empty() || result.back() != sample) result.push_back(sample);
            break;
        }
    }
    return result;
}

// Sample 8,000 positions per second of arranged playback. Group channels by
// power, avoiding cancellation where stereo polarities are opposite.
template<class PowerAtFrame>
void accumulate(const Span& span, Range range, double rate, std::int64_t frames,
                std::vector<double>& energy, const std::atomic<bool>& cancel, PowerAtFrame&& powerAtFrame) {
    if (range.first >= range.second || span.start >= range.second || span.end <= range.first ||
        rate <= 0 || frames <= 0 || cancel.load()) return;
    constexpr int samplesPerBin = 8;
    const double hz = envelopeHz * samplesPerBin;
    const int begin = std::max(0,int(std::ceil((std::max(span.start,range.first)-range.first) * hz)));
    const int end = std::min(int(energy.size()) * samplesPerBin,
        int(std::ceil((std::min(span.end,range.second)-range.first) * hz)));
    for (int i = begin; i < end; ++i) {
        if ((i % 1024) == 0 && cancel.load()) return;
        const double source = span.sourceAt(range.first + i / hz);
        if (!(source >= 0 && source < frames / rate)) continue;
        const auto frame = std::int64_t(source * rate);
        const auto power = powerAtFrame(frame);
        if (power < 0) return;
        energy[size_t(i/samplesPerBin)] += power;
    }
}

// Compare attack intervals in timeline seconds. Missing beats may contribute,
// but at least two intervals must directly support the proposed pulse.
inline std::optional<Estimate> estimate(const std::vector<double>& energy) {
    if (energy.size() < 4) return {};
    std::vector<double> flux(energy.size());
    double previous = 0;
    for (size_t i = 0; i < energy.size(); ++i) {
        const double level = std::sqrt(std::max(0., energy[i]));
        flux[i] = std::max(0., level - previous);
        previous += (level - previous) * .4;
    }
    auto sorted = flux;
    std::sort(sorted.begin(), sorted.end());
    const double gate = std::max({1e-8, sorted.back() * .065, sorted[sorted.size() * 3 / 4] * 2.5});
    std::vector<size_t> attacks;
    for (size_t i = 0; i < flux.size(); ++i) {
        if (flux[i] < gate || (i && flux[i-1] > flux[i]) || (i+1 < flux.size() && flux[i+1] >= flux[i])) continue;
        if (!attacks.empty() && i - attacks.back() < envelopeHz * .075) {
            if (flux[i] > flux[attacks.back()]) attacks.back() = i;
        } else attacks.push_back(i);
    }
    if (attacks.size() < 4) return {};
    std::vector<double> intervals;
    for (size_t i = 1; i < attacks.size(); ++i) intervals.push_back(double(attacks[i]-attacks[i-1]) / envelopeHz);
    double best = 0, bestPeriod = 0;
    for (double delta : intervals) for (int divisor = 1; divisor <= 3; ++divisor) {
        const double period = delta / divisor;
        if (period < .2 - .005 || period > 1.005) continue;
        int direct = 0, supported = 0, beats = 0;
        double seconds = 0, weight = 0;
        for (double span : intervals) {
            const int multiple = int(std::round(span / period));
            if (multiple < 1 || multiple > 4) continue;
            const double tolerance = std::max(.012, period * .055);
            const double error = std::abs(span - multiple * period);
            if (error > tolerance) continue;
            ++supported;
            if (multiple == 1) ++direct;
            beats += multiple;
            seconds += span;
            weight += (multiple == 1 ? 1. : .5) * (1. - .25 * error / tolerance);
        }
        if (direct < 2 || supported < 3 || supported < .65 * intervals.size() || weight <= best) continue;
        best = weight;
        bestPeriod = seconds / beats;
    }
    if (bestPeriod <= 0) return {};
    // Fit attack times against beat numbers. A regression over the pulse train
    // removes single-bin timing jitter without rounding fractional tempos.
    double refined = bestPeriod;
    size_t bestCount = 0;
    for (size_t anchor : attacks) {
        const double origin = double(anchor) / envelopeHz;
        double sx = 0, sy = 0, sxx = 0, sxy = 0;
        size_t count = 0;
        for (size_t attack : attacks) {
            const double t = double(attack) / envelopeHz - origin;
            const double n = std::round(t / bestPeriod);
            if (std::abs(t - n * bestPeriod) > std::max(.012, bestPeriod * .055)) continue;
            sx += n; sy += t; sxx += n*n; sxy += n*t;
            ++count;
        }
        if (count < 4 || count <= bestCount) continue;
        const double divisor = count*sxx - sx*sx;
        if (divisor <= 0) continue;
        const double fitted = (count*sxy - sx*sy) / divisor;
        if (std::abs(fitted - bestPeriod) > bestPeriod * .04) continue;
        refined = fitted;
        bestCount = count;
    }
    const double bpm = 60. / refined;
    if (bpm < 59.8 || bpm > 300.5) return {};
    return Estimate{std::clamp(bpm, 60., 300.), best};
}

inline std::optional<double> dominant(const std::vector<Estimate>& votes) {
    double best = 0, result = 0;
    for (const auto& candidate : votes) {
        double weight = 0, total = 0;
        for (const auto& other : votes) if (std::abs(other.bpm-candidate.bpm) <= candidate.bpm * .025) {
            weight += other.weight;
            total += other.bpm * other.weight;
        }
        if (weight > best) { best = weight; result = total / weight; }
    }
    if (!best) return {};
    return std::round(result * 100.) / 100.;
}
}
