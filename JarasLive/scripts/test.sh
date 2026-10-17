#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build/tests
c++ -std=c++17 -Wall -Wextra -Wno-missing-field-initializers Core/Project/Models.cpp Core/Transport/Engine.cpp Core/Import/TrackTaxonomy.cpp Tests/Core/CoreTests.cpp -o build/tests/core
build/tests/core
c++ -std=c++17 -Wall -Wextra -Wno-missing-field-initializers Core/Project/Models.cpp Core/Transport/Engine.cpp Core/Import/TrackTaxonomy.cpp Tests/Core/MultiLoopTests.cpp -o build/tests/multiloop
build/tests/multiloop
c++ -std=c++17 -Wall -Wextra -Wno-missing-field-initializers Core/Project/Models.cpp Core/Transport/Engine.cpp Core/Import/TrackTaxonomy.cpp Tests/Core/PlaybackScopeTests.cpp -o build/tests/playback-scope
build/tests/playback-scope
swift test --scratch-path build/swift-tests
