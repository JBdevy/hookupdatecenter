#pragma once
#include "TimelineMarqueeIndex.h"
#include <random>
#include <stdexcept>

namespace catlive::timelineMarqueeTests {
template<class Test> void registerTests(Test test) {
    test("Marquee index matches exhaustive selection across overlap lanes and scroll offsets", [] {
        TimelineMarqueeIndex index;
        std::vector<TimelineMarqueeIndex::Item> all;
        std::mt19937 random(108);
        for (int row=0; row<120; ++row) {
            std::vector<TimelineMarqueeIndex::Item> items;
            for (int n=0; n<160; ++n) {
                const double x=(random()%16000)/10., width=2+random()%240;
                const double y=row*112+3+(n%3)*24;
                items.push_back({std::to_string(row)+":"+std::to_string(n), {x,y,x+width,y+18}});
            }
            all.insert(all.end(),items.begin(),items.end());
            index.addRow(row*112,row*112+80,std::move(items));
        }
        for (int n=0; n<300; ++n) {
            const double x=(random()%18000)/10.-50,y=random()%14000;
            TimelineMarqueeIndex::Bounds box{x,y,x+1+random()%300,y+1+random()%300};
            std::set<std::string> expected{"existing-selection"},selected=expected;
            for (const auto &item:all) if (item.bounds.intersects(box)) expected.insert(item.id);
            index.select(box,selected);
            if(selected!=expected)throw std::runtime_error("Indexed marquee differs from actual item rectangles");
        }
        index.clear();
        std::set<std::string> cleared;index.select({0,0,2000,15000},cleared);
        if(!cleared.empty() || index.bounds("0:0"))throw std::runtime_error("Old project rectangles survived reset");
    });
    test("Marquee visits only nearby items in a long multitrack project", [] {
        TimelineMarqueeIndex index;
        for (int row=0; row<200; ++row) {
            std::vector<TimelineMarqueeIndex::Item> items;
            for(int n=0;n<500;++n)items.push_back({std::to_string(row)+":"+std::to_string(n),
                {double(n*40),double(row*100),double(n*40+30),double(row*100+80)}});
            index.addRow(row*100,row*100+80,std::move(items));
        }
        size_t visits=0;
        std::set<std::string> selected;
        index.select({8005,9002,8085,9160},selected,&visits);
        if(selected.size()!=6 || visits!=6)throw std::runtime_error("Small selection scanned unrelated tracks/items");
        // Exact touches are not overlaps, including gaps between track bodies.
        selected.clear();index.select({8030,9080,8040,9100},selected);
        if(!selected.empty())throw std::runtime_error("Empty boundary/gap selected an item");
    });
}
}
