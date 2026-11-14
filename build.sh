#!/bin/sh
# Simmer build script.
#
#   ./build.sh            build Simmer.app (Release, ad-hoc signed) into ./build
#   ./build.sh test       run the SimmerCore unit tests
#   ./build.sh probe      read-only check of this Mac's SMC keys and battery telemetry
#   ./build.sh run        build, then launch the app
#   ./build.sh clean      remove build output
#
# Environment: CONFIG=Debug|Release (default Release)
#              SIGN_IDENTITY="Developer ID Application: …" (default "-" = ad-hoc)
set -eu
cd "$(dirname "$0")"

CONFIG="${CONFIG:-Release}"
SIGN_IDENTITY="${SIGN_IDENTITY:--}"
OUT="build"
DERIVED="$OUT/DerivedData"
APP="$OUT/Simmer.app"

build_app() {
    echo "==> Building Simmer ($CONFIG)"
    xcodebuild -project Simmer.xcodeproj -scheme Simmer -configuration "$CONFIG" \
        -derivedDataPath "$DERIVED" -destination "platform=macOS,arch=$(uname -m)" -quiet \
        CODE_SIGN_IDENTITY="$SIGN_IDENTITY" build

    rm -rf "$APP"
    ditto "$DERIVED/Build/Products/$CONFIG/Simmer.app" "$APP"

    echo "==> Verifying signature"
    codesign --verify --deep --strict "$APP"
    codesign -dv "$APP" 2>&1 | grep -E "Identifier|Signature|TeamIdentifier" | sed 's/^/    /'
    echo "==> Built $APP"
}

case "${1:-build}" in
    build)
        build_app
        ;;
    test)
        echo "==> Running SimmerCore tests"
        swift test --package-path SimmerCore
        ;;
    probe)
        swift run --package-path SimmerCore simmerctl probe
        swift run --package-path SimmerCore simmerctl caps
        swift run --package-path SimmerCore simmerctl battery
        ;;
    run)
        build_app
        open "$APP"
        ;;
    clean)
        rm -rf "$OUT" SimmerCore/.build
        ;;
    *)
        echo "usage: $0 [build|test|probe|run|clean]" >&2
        exit 64
        ;;
esac
