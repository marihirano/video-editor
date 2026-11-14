#!/bin/zsh
# Builds a release version of the app and packages it as build/Video Editor.app
# Usage: scripts/build-app.sh
set -euo pipefail
cd "$(dirname "$0")/.."

APP="build/Video Editor.app"

swift build -c release --product VideoEditor
BIN="$(swift build -c release --product VideoEditor --show-bin-path)/VideoEditor"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/VideoEditor"
cp Resources/Info.plist "$APP/Contents/Info.plist"
# App icon (redraw it with: swift scripts/make-icon.swift)
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
# The interface font (Inter, with its licence)
cp -R Resources/Fonts "$APP/Contents/Resources/Fonts"

# Sign with the app's own stable certificate (see signing.sh), so the screen recording permission
# survives rebuilds. Falls back to an ad-hoc signature (permission asked again after each build).
source scripts/signing.sh
if [[ -n "$SIGN_IDENTITY" ]] && codesign --force --sign "$SIGN_IDENTITY" --identifier com.marihirano.video-editor "$APP"; then
    echo "Signed with a stable certificate ($SIGN_IDENTITY)."
else
    # Ad-hoc, but told to be recognised by its bundle id rather than by this exact build's
    # fingerprint, so macOS keeps the screen recording permission across rebuilds.
    codesign --force --sign - --identifier com.marihirano.video-editor \
        -r='designated => identifier "com.marihirano.video-editor"' "$APP"
    echo "Signed ad-hoc, recognised by its bundle id (permission should survive rebuilds)."
fi

# Tell Finder about the app's file types (project packages).
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$APP" || true

echo "Built: $APP"
