#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build/bridge-tests
cat > build/bridge-tests/main.swift <<'SWIFT'
import Foundation
let data = try JSONEncoder().encode(Project.demo())
try data.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
SWIFT
swiftc Application/Project/ProjectModels.swift build/bridge-tests/main.swift -o build/bridge-tests/fixture
build/bridge-tests/fixture build/bridge-tests/demo.json
clang++ -std=c++17 -fobjc-arc -framework Foundation Core/Project/Models.cpp Core/Transport/Engine.cpp Core/Import/TrackTaxonomy.cpp Apple/Bridge/JarasCoreBridge.mm Tests/Core/BridgeTests.mm -o build/bridge-tests/test
build/bridge-tests/test build/bridge-tests/demo.json
