#pragma once
#include "Common.h"
namespace catlive {
struct ItemTextColors {
    struct Run { String text; std::optional<uint32> color; };
    static String prefix() { return String::charToString(30)+"CatLiveText/1\n"; }
    static String columnsPrefix() { return String::charToString(30)+"CatLiveColumns/1\n"; }
    static StringArray columns(const String &value) {
        if(value.startsWith(columnsPrefix())) {
            const auto data=JSON::parse(value.substring(columnsPrefix().length()));
            if(auto *array=data.getArray();array && array->size()==2 && (*array)[0].isString() && (*array)[1].isString()
               && !(*array)[0].toString().startsWith(columnsPrefix()) && !(*array)[1].toString().startsWith(columnsPrefix()))
                return {(*array)[0].toString(),(*array)[1].toString()};
        }
        return {value};
    }
    static String encodeColumns(const String &first,const String &second) {
        Array<var> values;values.add(first);values.add(second);return columnsPrefix()+JSON::toString(var(values),true);
    }
    static std::vector<Run> runs(const String &value) {
        const auto parts=columns(value);
        if(parts.size()==2) { auto result=runs(parts[0]);result.push_back({"\n",{}});auto tail=runs(parts[1]);result.insert(result.end(),tail.begin(),tail.end());return result; }
        if(value.startsWith(prefix())) {
            const auto data=JSON::parse(value.substring(prefix().length()));
            if(data.isArray()) {
                std::vector<Run> result;
                for(const auto &entry:*data.getArray()) {
                    if(!entry.isObject() || !get(entry,"text").isString())return {{value,{}}};
                    const auto color=get(entry,"color");
                    if(!color.isVoid() && !color.isUndefined() && (!color.isInt() && !color.isInt64()))return {{value,{}}};
                    if(!color.isVoid() && !color.isUndefined() && ((int64)color<0 || (int64)color>0xffffff))return {{value,{}}};
                    result.push_back({str(entry,"text"),color.isVoid()||color.isUndefined()?std::nullopt:std::optional<uint32>((uint32)(int64)color)});
                }
                return result;
            }
        }
        return {{value,{}}};
    }
    static String plain(const String &value) { String text;for(const auto &run:runs(value))text+=run.text;return text; }
    static String encode(const std::vector<Run> &runs) {
        Array<var> values;String plain;bool colored=false;
        for(const auto &run:runs)if(run.text.isNotEmpty()) {
            plain+=run.text;auto value=object();put(value,"text",run.text);
            if(run.color){put(value,"color",(int64)*run.color);colored=true;}values.add(value);
        }
        return colored?prefix()+JSON::toString(var(values),true):plain;
    }
    static std::vector<Range<int>> stanzaRanges(const String &plain) {
        std::vector<Range<int>> result;
        int lineStart = 0, first = -1, end = 0, blank = 0;
        const int size = plain.length();
        for (int i = 0; i <= size; ++i) {
            if (i < size && plain[i] != '\n' && plain[i] != '\r') continue;
            if (plain.substring(lineStart, i).trim().isEmpty()) ++blank;
            else {
                if (blank >= 2 && first >= 0) { result.emplace_back(first, end); first = -1; }
                if (first < 0) first = lineStart;
                end = i;
                blank = 0;
            }
            if (i + 1 < size && plain[i] == '\r' && plain[i + 1] == '\n') ++i;
            lineStart = i + 1;
        }
        if (first >= 0) result.emplace_back(first, end);
        return result;
    }
    static std::vector<String> stanzas(const String &value) {
        const auto formatted = runs(value);
        String plain;
        for (const auto &run : formatted) plain += run.text;
        const auto ranges = stanzaRanges(plain);
        std::vector<std::vector<Run>> slices(ranges.size());
        int offset = 0;
        size_t next = 0;
        for (const auto &run : formatted) {
            const int end = offset + run.text.length();
            while (next < ranges.size() && ranges[next].getStart() < end) {
                const auto slice = ranges[next].getIntersectionWith({offset, end});
                if (!slice.isEmpty()) {
                    auto piece = run.text.substring(slice.getStart() - offset, slice.getEnd() - offset);
                    slices[next].push_back({piece.replace("\r\n", "\n").replace("\r", "\n"), run.color});
                }
                if (ranges[next].getEnd() > end) break;
                ++next;
            }
            offset = end;
        }
        std::vector<String> result;
        for (const auto &slice : slices) result.push_back(encode(slice));
        return result;
    }
    static constexpr std::array<uint32,8> palette{0xffffff,0xff4040,0xff9638,0xffe740,0x54ef86,0x40dfff,0x5894ff,0xd477ff};
    static AttributedString attributed(const String &value,const Font &font,Colour fallback,
        const std::function<String(String)> &display={}) {
        AttributedString text;
        for(const auto &run:runs(value))text.append(display?display(run.text):run.text,font,run.color?Colour(0xff000000|*run.color):fallback);
        return text;
    }
    static void draw(Graphics &g,const String &value,juce::Rectangle<float> area,const Font &font,Colour fallback,
                     Justification alignment,const std::function<String(String)> &display={}) {
        auto text=attributed(value,font,fallback,display);text.setJustification(alignment);
        text.draw(g,area);
    }
};
}
