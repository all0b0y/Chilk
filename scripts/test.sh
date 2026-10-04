#!/bin/zsh
# Unit tests (ChilkCore) + regenerate the static AppIcon from the renderer.
set -euo pipefail
cd "${0:A:h}/../ChilkKit"
swift test 2>&1 | grep -E "✘|Test run|error:" || true
swift run -q chilk-render icon ../Chilk/Resources/Assets.xcassets/AppIcon.appiconset
