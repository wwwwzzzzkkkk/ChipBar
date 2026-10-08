#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
DEV_DIR="$(xcode-select -p)"
TEST_FRAMEWORKS="$DEV_DIR/Library/Developer/Frameworks"
TEST_PLUGIN="$DEV_DIR/usr/lib/swift/host/plugins/testing/libTestingMacros.dylib"
if [[ "$DEV_DIR" == */CommandLineTools && -f "$TEST_PLUGIN" && -d "$TEST_FRAMEWORKS/Testing.framework" ]]; then
    # CLT has Swift Testing but no XCTest. The native runner avoids nested test
    # bundle signing in Documents folders managed by macOS File Provider.
    swift test --build-system native --disable-xctest \
        -Xswiftc -F -Xswiftc "$TEST_FRAMEWORKS" \
        -Xswiftc -load-plugin-library -Xswiftc "$TEST_PLUGIN" \
        -Xlinker -rpath -Xlinker "$TEST_FRAMEWORKS"
else
    swift test --disable-xctest
fi
