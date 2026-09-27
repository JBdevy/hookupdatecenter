#pragma once
#include "../Transport/Engine.hpp"
#include <cstdint>
namespace jaras { struct MIDIControlBinding { uint8_t channel = 0, controller = 0; Command command; }; }
