#!/bin/zsh
# Build Chilk.app (Debug) → build/DerivedData/Build/Products/Debug/Chilk.app
set -euo pipefail
cd "${0:A:h}/.."
xcodegen generate --quiet
xcodebuild -project Chilk.xcodeproj -scheme Chilk -configuration "${CONFIGURATION:-Debug}" \
  -derivedDataPath build/DerivedData -destination 'platform=macOS' build 2>&1 \
  | grep -E "(error|warning):|BUILD (SUCCEEDED|FAILED)" | grep -v "appintentsmetadataprocessor" || true
APP="build/DerivedData/Build/Products/${CONFIGURATION:-Debug}/Chilk.app"
[ -d "$APP" ] && echo "$PWD/$APP"
