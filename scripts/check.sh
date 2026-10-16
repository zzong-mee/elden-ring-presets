#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build
"${CXX:-g++}" -std=c++17 -Wall -Wextra -Wpedantic -Werror -Iinclude src/presets.cpp tests/presets_test.cpp -o build/presets_test
build/presets_test
python3 -m unittest discover -s tests -p 'test_*.py' -v
