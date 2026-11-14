#include "../../Core/Loop/MultiLoopEditing.hpp"
#include <cassert>
#include <iostream>
int main() {
    using namespace jaras;
    const std::vector<ID> rows{"a", "b", "c", "d", "e", "f"};
    MultiLoopTrackSelection selection;
    selection.select("b", rows); selection.select("e", rows, true);
    assert((selection.ids == std::set<ID>{"b", "c", "d", "e"}));
    selection.select("c", rows, true);
    assert((selection.ids == std::set<ID>{"b", "c"}));
    selection.select("f", rows, false, true);
    assert((selection.targets("c") == std::set<ID>{"b", "c", "f"}));
    selection.select("c", rows, false, true);
    assert((selection.ids == std::set<ID>{"b", "f"}));
    assert((selection.targets("a") == std::set<ID>{"a"}));
    const MultiLoopGainDrag drag("a", {"a", "b"}, {{"a", .5}, {"b", .25}, {"outside", 1}}, {{"a", 1}, {"b", .3}});
    assert((drag.gains(1) == std::map<ID, double>{{"a", 1}, {"b", .3}}));
    assert((drag.gains(.25) == std::map<ID, double>{{"a", .25}, {"b", .125}}));
    assert((drag.gains(0) == std::map<ID, double>{{"a", 0}, {"b", 0}}));
    assert((drag.gains(.5) == std::map<ID, double>{{"a", .5}, {"b", .25}}));
    assert(drag.gains(NAN).empty());
    std::cout << "MULTILOOP_SELECTION_RANGE_TOGGLE_CONTROL_TARGETS_BALANCE_AND_CEILING_REVERSAL_OK\n";
}
