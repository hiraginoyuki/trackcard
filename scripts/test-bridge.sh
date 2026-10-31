#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
test_directory="$(mktemp -d "${TMPDIR:-/tmp}/trackcard-bridge.XXXXXX")"
trap 'rm -rf "$test_directory"' EXIT
xcrun clang++ -std=c++17 -pthread -I Sources/TrackpadBridge/include \
    Tests/TrackpadBridgeTests/main.cpp -framework CoreFoundation -framework IOKit \
    -o "$test_directory/bridge-tests"
"$test_directory/bridge-tests"
