#pragma once
#include "NativeSession.h"

namespace catlive::native {
// Control-thread JSON boundary. Throws std::invalid_argument for malformed or
// unknown actions; a rejected request leaves document, transport and history intact.
nlohmann::json applySessionAction(NativeSession&, const nlohmann::json& request);
}
