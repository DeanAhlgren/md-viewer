#!/bin/zsh
# Builds MD Viewer.app and installs it to ~/Applications
set -e
cd "$(dirname "$0")"

APP="${MDVIEWER_APP_PATH:-$HOME/Applications/MD Viewer.app}"

echo "Compiling…"
clang -fobjc-arc -O2 main.m -o MDViewer \
    -framework Cocoa -framework WebKit -framework UniformTypeIdentifiers

if [ ! -f Resources/AppIcon.icns ]; then
    echo "Generating icon…"
    clang -fobjc-arc makeicon.m -o makeicon -framework Cocoa
    iconset=$(mktemp -d)/AppIcon.iconset
    mkdir -p "$iconset"
    ./makeicon "$iconset/icon_512x512@2x.png"
    for s in 16 32 128 256 512; do
        sips -z $s $s "$iconset/icon_512x512@2x.png" --out "$iconset/icon_${s}x${s}.png" >/dev/null
        d=$((s * 2))
        sips -z $d $d "$iconset/icon_512x512@2x.png" --out "$iconset/icon_${s}x${s}@2x.png" >/dev/null
    done
    iconutil -c icns "$iconset" -o Resources/AppIcon.icns
fi

echo "Assembling bundle…"
if [ -d "$APP" ]; then
    backup="${APP%.app}.backup-$(date +%Y%m%d-%H%M%S).app"
    mv "$APP" "$backup"
    echo "Previous version: $backup"
fi
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp MDViewer "$APP/Contents/MacOS/"
cp Info.plist "$APP/Contents/"
cp Resources/template.html Resources/marked.min.js Resources/highlight.min.js Resources/AppIcon.icns "$APP/Contents/Resources/"

codesign --force --sign - "$APP"

if [ "${MDVIEWER_REGISTER:-1}" = 1 ]; then
    echo "Registering with Launch Services…"
    /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$APP"
fi

echo "Done: $APP"
