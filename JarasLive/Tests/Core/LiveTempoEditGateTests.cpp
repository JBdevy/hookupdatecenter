#include "../../Core/Transport/TempoEditGate.hpp"
#include <stdexcept>
#include <iostream>
void check(bool value){if(!value)throw std::runtime_error("Live tempo admission failed");}
int main(){
    jaras::LiveTempoEditGate gate;
    check(gate.accept(true,10));
    for(double now:{10.001,10.2,10.499})check(!gate.accept(true,now));
    check(gate.accept(true,10.5));
    check(!gate.accept(true,10.999));
    check(gate.accept(false,11));check(gate.accept(false,11));
    check(gate.accept(true,11));
    gate.reset();check(gate.accept(true,11.01));
    std::cout<<"LIVE_TEMPO_IMMEDIATE_500MS_SHARED_DIRECTION_NO_QUEUE_STOP_RESET_OK\n";
}
