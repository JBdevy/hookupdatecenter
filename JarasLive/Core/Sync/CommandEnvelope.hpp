#pragma once
#include "../Transport/Engine.hpp"
#include <cstdint>
namespace jaras { struct CommandEnvelope { unsigned protocolVersion = 1; uint64_t sequence = 0; ID installationId; Command command; }; }
