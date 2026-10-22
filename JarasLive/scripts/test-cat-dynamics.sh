#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
dynamics_build_dir="$(mktemp -d "${TMPDIR:-/tmp}/catlive-dynamics.XXXXXX")"
trap 'rm -rf "$dynamics_build_dir"' EXIT
"${CXX:-c++}" -std=c++17 -O2 -Wall -Wextra -Werror -pedantic \
    Tests/Core/CatDynamicsDSPTests.cpp -o "$dynamics_build_dir/tests"
"$dynamics_build_dir/tests"
