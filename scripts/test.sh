#!/bin/zsh
set -euo pipefail
cd "${0:A:h}/.."
developer_dir="$(xcode-select -p)"
swift test -c release --disable-xctest \
  -Xswiftc -F -Xswiftc "$developer_dir/Library/Developer/Frameworks" \
  -Xlinker -rpath -Xlinker "$developer_dir/Library/Developer/Frameworks" \
  -Xlinker -rpath -Xlinker "$developer_dir/Library/Developer/usr/lib"
