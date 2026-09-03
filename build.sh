#!/bin/zsh
# Builds MD Viewer.app and installs it to ~/Applications
set -e
cd "$(dirname "$0")"

APP="$HOME/Applications/MD Viewer.app"

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
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp MDViewer "$APP/Contents/MacOS/"
cp Info.plist "$APP/Contents/"
cp Resources/template.html Resources/marked.min.js Resources/highlight.min.js Resources/AppIcon.icns "$APP/Contents/Resources/"

codesign --force --sign - "$APP"

echo "Registering with Launch Services…"
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$APP"

echo "Done: $APP"
