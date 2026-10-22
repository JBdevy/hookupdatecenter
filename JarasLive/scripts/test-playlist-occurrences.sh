#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build/tests
c++ -std=c++17 -Wall -Wextra -Wno-missing-field-initializers Core/Project/Models.cpp Core/Transport/Engine.cpp Core/Import/TrackTaxonomy.cpp Tests/Core/PlaylistOccurrenceTests.cpp -o build/tests/playlist-occurrences
build/tests/playlist-occurrences
