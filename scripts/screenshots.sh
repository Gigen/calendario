#!/bin/bash
# Regenerates docs/screenshots/*.png from the app's demo mode: fictional calendars
# and reminders, a neutral time zone and locale. Nothing from your own calendars,
# Keychain or Google accounts is read.
#
# The demo copy is built under its own bundle ID, so it has its own sandbox
# container and never touches the installed app's settings. A window appears for a
# few seconds per screenshot; the app renders it itself (no Screen Recording needed).

set -euo pipefail
cd "$(dirname "$0")/.."

DEMO_ID=dev.calendario.demo
BUILD=build/demo
APP="$BUILD/Build/Products/Debug/Calendario.app"
CONTAINER="$HOME/Library/Containers/$DEMO_ID/Data/tmp"
OUT=docs/screenshots

xcodebuild -project Calendario.xcodeproj -scheme Calendario -configuration Debug -derivedDataPath "$BUILD" \
    CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM= PRODUCT_BUNDLE_IDENTIFIER=$DEMO_ID GOOGLE_CLIENT_ID= build >/dev/null
mkdir -p "$OUT"

shoot() {
    local name=$1; shift
    rm -f "$CONTAINER/demo-ready" "$CONTAINER/demo-shot.png"
    open -n --env TZ=America/New_York "$APP" --args -demo YES -demoStage YES -ApplePersistenceIgnoreState YES \
        -AppleLocale en_US -AppleLanguages "(en)" "$@"
    for _ in $(seq 1 60); do [[ -f $CONTAINER/demo-shot.png ]] && break; sleep 0.5; done
    sleep 0.5
    pkill -f "$APP/Contents/MacOS/Calendario" || true
    cp "$CONTAINER/demo-shot.png" "$OUT/$name.png"
    echo "  $OUT/$name.png"
    sleep 1
}

pastel=(-theme.palette pastel -theme.background dots -theme.events solid -theme.reminders dashed -theme.canvas "#FAF5EB")
patterns=(-theme.palette pastel -theme.background grid -theme.events stripes -theme.reminders dotted)

shoot days-light    -demoView days -dayCount 5 -theme.appAppearance light
shoot month-pastel  -demoView month -theme.appAppearance light "${pastel[@]}"
shoot days-dark     -demoView days -dayCount 5 -theme.appAppearance dark "${patterns[@]}"
shoot days-patterns -demoView days -dayCount 4 -theme.appAppearance light "${patterns[@]}" -theme.canvas "#EEF4FB"
shoot editor        -demoView days -dayCount 5 -demoExtra editor -theme.appAppearance light
shoot inbox         -demoView days -dayCount 5 -demoExtra inbox -theme.appAppearance light
shoot reminders     -demoView reminders -theme.appAppearance light
shoot settings      -demoView days -demoExtra settings -theme.appAppearance light "${patterns[@]}" -theme.canvas "#EEF4FB"
