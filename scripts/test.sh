#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
DEVELOPER_ROOT="$(xcode-select -p)"
FRAMEWORKS="$DEVELOPER_ROOT/Library/Developer/Frameworks"
if [[ "$DEVELOPER_ROOT" == */CommandLineTools && -d "$FRAMEWORKS/Testing.framework" ]]; then
    swift test -Xswiftc -F -Xswiftc "$FRAMEWORKS" \
        -Xswiftc -load-plugin-library \
        -Xswiftc "$DEVELOPER_ROOT/usr/lib/swift/host/plugins/testing/libTestingMacros.dylib" \
        -Xlinker -F -Xlinker "$FRAMEWORKS" \
        -Xlinker -rpath -Xlinker "$FRAMEWORKS" "$@"
else
    swift test "$@"
fi
