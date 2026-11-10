#!/usr/bin/env bash
# Builds WristFlow.app into ./build. Pass --install to copy it to ~/Applications and launch it
# from there, or --run to launch the build copy (extra args after --run go to the app).
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release

APP=build/WristFlow.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/WristFlow "$APP/Contents/MacOS/"
cp Resources/Info.plist "$APP/Contents/"

# A real signing identity keeps the Camera and Accessibility grants across rebuilds. Without
# one the app is signed ad hoc and macOS asks again after every build.
IDENTITY=$(security find-identity -v -p codesigning | awk -F'"' '/Apple Development|Developer ID Application/ {print $2; exit}')
codesign --force --sign "${IDENTITY:--}" "$APP"
if [ -n "$IDENTITY" ]; then
  echo "Built $APP (signed)"
else
  echo "Built $APP (ad hoc signature)"
fi

case "${1:-}" in
  --install)
    pkill -x WristFlow 2>/dev/null || true
    rm -rf ~/Applications/WristFlow.app
    mkdir -p ~/Applications
    cp -R "$APP" ~/Applications/
    echo "Installed to ~/Applications/WristFlow.app"
    open ~/Applications/WristFlow.app
    ;;
  --run)
    shift
    pkill -x WristFlow 2>/dev/null || true
    open "$APP" --args "$@"
    ;;
esac
