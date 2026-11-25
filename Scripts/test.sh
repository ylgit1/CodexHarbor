#!/bin/zsh
# Run the complete SwiftPM suite using the selected Apple toolchain.
# Some Command Line Tools releases ship Swift Testing outside Swift's
# default search paths. Keep these flags local to the test invocation.
set -euo pipefail
cd "${0:A:h}/.."
developer_dir="${DEVELOPER_DIR:-$(/usr/bin/xcode-select -p)}"
if [[ -d "$developer_dir/Library/Developer/Frameworks/Testing.framework" ]]; then
  frameworks="$developer_dir/Library/Developer/Frameworks"
  libraries="$developer_dir/Library/Developer/usr/lib"
  exec /usr/bin/xcrun swift test \
    -Xswiftc -F -Xswiftc "$frameworks" \
    -Xlinker "-F$frameworks" \
    -Xlinker -rpath -Xlinker "$frameworks" \
    -Xlinker "-L$libraries" \
    -Xlinker -rpath -Xlinker "$libraries" \
    --no-parallel "$@"
fi
exec /usr/bin/xcrun swift test --no-parallel "$@"
