#pragma once
#include <algorithm>
#include <cmath>
#include <iterator>
#include <stdexcept>
#include <vector>

namespace catlive::audio {
// Continuous, strictly increasing affine segments. Construction/composition is
// control-only; forward/inverse lookup is bounded binary search without heap use.
class PiecewiseTimeMap {
public:
    struct Segment { double start, output, scale; };
    explicit PiecewiseTimeMap(double scale=1.) : baseScale(scale) {
        if(!std::isfinite(scale)||scale<=0)throw std::invalid_argument("Invalid time scale");
    }
    void append(double start,double output,double scale) {
        if(!std::isfinite(start)||!std::isfinite(output)||!std::isfinite(scale)||scale<=0 ||
           (!segments.empty()&&start<=segments.back().start))
            throw std::invalid_argument("Invalid time map segment");
        segments.push_back({start,output,scale});
    }
    double position(double time) const noexcept {
        if(!std::isfinite(time))return time;
        const auto i=std::upper_bound(segments.begin(),segments.end(),time,
            [](double t,const Segment& s){return t<s.start;});
        if(i==segments.begin())return time*baseScale+baseOffset;
        const auto& s=*std::prev(i);return s.output+(time-s.start)*s.scale;
    }
    double inverse(double time) const noexcept {
        if(!std::isfinite(time))return time;
        const auto i=std::upper_bound(segments.begin(),segments.end(),time,
            [](double t,const Segment& s){return t<s.output;});
        if(i==segments.begin())return (time-baseOffset)/baseScale;
        const auto& s=*std::prev(i);return s.start+(time-s.output)/s.scale;
    }
    double slope(double time) const noexcept {
        const auto i=std::upper_bound(segments.begin(),segments.end(),time,
            [](double t,const Segment& s){return t<s.start;});
        return i==segments.begin()?baseScale:std::prev(i)->scale;
    }
    PiecewiseTimeMap followedBy(const PiecewiseTimeMap& next) const {
        std::vector<double> points;points.reserve(segments.size()+next.segments.size());
        for(const auto& s:segments)points.push_back(s.start);
        for(const auto& s:next.segments)points.push_back(inverse(s.start));
        std::sort(points.begin(),points.end());
        points.erase(std::unique(points.begin(),points.end()),points.end());
        PiecewiseTimeMap result(baseScale*next.baseScale);
        result.baseOffset=baseOffset*next.baseScale+next.baseOffset;
        result.segments.reserve(points.size());
        for(double start:points) {
            const double mapped=position(start),output=next.position(mapped);
            // Use an interior point, avoiding rounding to the preceding segment
            // at a breakpoint reconstructed through inverse().
            const auto following=std::upper_bound(points.begin(),points.end(),start);
            const double probe=following==points.end()?std::nextafter(start,INFINITY):start+(*following-start)*.5;
            const double scale=slope(probe)*next.slope(position(probe));
            const double prior=result.segments.empty()?result.baseScale:result.segments.back().scale;
            if(scale!=prior || std::abs(result.position(start)-output)>1e-10)
                result.append(start,output,scale);
        }
        return result;
    }
    void swap(PiecewiseTimeMap& other) noexcept {
        segments.swap(other.segments);std::swap(baseScale,other.baseScale);std::swap(baseOffset,other.baseOffset);
    }
private:
    double baseScale=1.,baseOffset=0.;
    std::vector<Segment> segments;
};
}
