#pragma once
#include "Common.h"
namespace catlive {
struct ItemTextColors {
    struct Run { String text; std::optional<uint32> color; };
    static String prefix() { return String::charToString(30)+"CatLiveText/1\n"; }
    static std::vector<Run> runs(const String &value) {
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
