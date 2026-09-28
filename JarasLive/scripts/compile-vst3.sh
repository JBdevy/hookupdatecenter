#!/bin/bash
set -euo pipefail
build_dir="$1"
clang++ -std=c++17 -fobjc-arc -ICore/ThirdParty/VST3 -c Apple/Bridge/JarasVST3.mm -o "$build_dir/vst3.o"
for source in Core/ThirdParty/VST3/pluginterfaces/base/*.cpp; do
 clang++ -std=c++17 -ICore/ThirdParty/VST3 -c "$source" -o "$build_dir/vst3-$(basename "$source" .cpp).o"
done
