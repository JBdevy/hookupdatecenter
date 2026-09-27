#pragma once
#include "../Project/Models.hpp"
namespace jaras { class ProjectImporter { public: virtual ~ProjectImporter() = default; virtual Project scan(const std::string& folder) = 0; }; }
