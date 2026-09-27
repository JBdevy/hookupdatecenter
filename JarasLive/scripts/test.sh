#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build/tests
c++ -std=c++17 -Wall -Wextra -Wno-missing-field-initializers Core/Project/Models.cpp Core/Transport/Engine.cpp Core/Import/TrackTaxonomy.cpp Tests/Core/CoreTests.cpp -o build/tests/core
build/tests/core
swift test --scratch-path build/swift-tests
