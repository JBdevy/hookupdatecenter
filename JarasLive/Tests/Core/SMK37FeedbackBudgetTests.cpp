#include "SMK37FeedbackBudget.h"
#include <cassert>
#include <limits>
#include <iostream>

int main() {
    catlive::SMK37FeedbackBudget budget;
    assert(budget.allow(95, 0));
    assert(!budget.allow(95, 0));
    assert(!budget.allow(10, .01));
    assert(budget.allow(10, .02));
    assert(!budget.allow(97, 1));
    assert(!budget.allow(0, 1));
    assert(!budget.allow(10, std::numeric_limits<double>::quiet_NaN()));
    assert(!budget.allow(10, -1));
    catlive::SMK37FeedbackBudget flood;
    int total = 0;
    double last = -1;
    for (int step = 0; step <= 2000; ++step) {
        const double now = step / 1000.;
        if (flood.allow(80, now)) {
            assert(now - last >= .02 - 1e-9);
            last = now;
            total += 80;
        }
    }
    assert(total <= 96 + 2400 && total > 2000);
    budget = {};
    assert(budget.allow(96, 0));
    std::cout << "SMK37_WINDOWS_FEEDBACK_BURST_SPACING_RATE_RESET_OK\n";
}
