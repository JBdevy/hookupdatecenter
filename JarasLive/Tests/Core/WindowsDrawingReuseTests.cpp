#include "../../Windows/Source/TimelineGridCache.h"
#include <iostream>
#include <stdexcept>

int main() {
    catlive::TimelineGridCache<int> cache;
    int calls = 0;
    const auto build = [&] { ++calls; return std::vector<int>{calls}; };
    const auto require = [](bool value, const char* message) { if (!value) throw std::runtime_error(message); };
    const auto* first = cache.get("project", "song", 1, 0, 120, 10, build).data();
    for (int i = 0; i < 600; ++i)
        require(cache.get("project", "song", 1, 0, 120, 10, build).data() == first, "Unchanged repaints must retain the same grid");
    require(calls == 1 && cache.hits == 600, "Unchanged grid recomputed its labels");
    cache.get("project", "song", 1, 1, 121, 10, build);
    require(calls == 2, "Panning must rebuild visible divisions");
    cache.get("project", "song", 1, 1, 61, 20, build);
    require(calls == 3, "Zoom must rebuild divisions and label density");
    cache.get("project", "song", 2, 1, 61, 20, build);
    require(calls == 4, "Tempo/time-signature edits must replace the old ruler");
    cache.get("project", "other-song", 2, 1, 61, 20, build);
    cache.get("other-project", "other-song", 2, 1, 61, 20, build);
    require(calls == 6, "Project and song switches must not retain old labels");
    cache.invalidate();
    cache.get("other-project", "other-song", 2, 1, 61, 20, build);
    require(calls == 7, "Region drag previews must invalidate before the project revision changes");
    const auto& empty = cache.get("other-project", "other-song", 3, 1, 61, 20, [] { return std::vector<int>{}; });
    require(empty.empty(), "Empty grids must remove old divisions");
    catlive::TimelineRegionDrawingCache<int> regions;
    int formatted=0;
    const auto buildRegions=[&] {
        std::vector<catlive::TimelineRegionDrawingCache<int>::Entry> entries;
        for(size_t i=0;i<6000;++i) {++formatted;entries.push_back({double(i*10),double(i*10+12),i,int(i)});}
        // Long enclosing regions must survive the prefix search. Drawing order
        // must follow the document even when its array is not chronological.
        entries.push_back({0,60000,6000,6000});
        std::reverse(entries.begin(),entries.end());return entries;
    };
    for(int frame=0;frame<1000;++frame) {
        regions.prepare("project","song",1,false,buildRegions);
        const double start=frame*50,end=start+40;
        const auto visible=regions.visible(start,end);
        std::vector<size_t> expected;
        for(size_t i=0;i<6000;++i)if(i*10<=end && i*10+12>=start)expected.push_back(i);
        expected.push_back(6000);
        require(visible.size()==expected.size(),"Indexed viewport lost a region boundary/overlap");
        for(size_t i=0;i<expected.size();++i)require(visible[i]->sourceIndex==expected[i],"Region paint order changed");
    }
    require(formatted==6000 && regions.builds==1,"Zoom reshaped unchanged region labels");
    regions.prepare("project","song",2,false,buildRegions);
    regions.prepare("project","song",2,true,buildRegions);
    regions.invalidate();regions.prepare("project","song",2,true,buildRegions);
    regions.prepare("other-project","song",2,true,buildRegions);
    require(regions.builds==5,"Edit, language, drag preview or project switch retained stale regions");
    regions.prepare("project","empty",1,false,[]{return std::vector<catlive::TimelineRegionDrawingCache<int>::Entry>{};});
    require(regions.visible(0,100).empty(),"Empty project retained regions");
    std::cout << "WINDOWS_6001_REGIONS_1000_ZOOM_FRAMES_RETAIN_LABELS_AND_EXACT_VISIBILITY_OK\n";
    std::cout << "WINDOWS_GRID_REUSE_PAN_ZOOM_EDIT_PREVIEW_AND_PROJECT_INVALIDATION_OK\n";
}
