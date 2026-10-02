#!/bin/sh
# Builds /Applications/Waffle.app (or $APP). `./build.sh test` only runs the self-check.
# Needs: Apple Silicon, macOS 15+, Xcode command line tools and `brew install whisper-cpp` (install.sh sets these up). Summaries need Claude Code or Codex.
set -e
cd "$(dirname "$0")"
mkdir -p .build
swiftc -swift-version 5 Sources/Waffle/Logic.swift Tests/main.swift -o .build/selftest && .build/selftest
[ "$1" = test ] && exit 0

APP="${APP:-/Applications/Waffle.app}"
MODEL=models/ggml-parakeet-tdt-0.6b-v3-q8_0.bin
swift build -c release --product Waffle
BIN=$(swift build -c release --show-bin-path)

mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/Waffle" "$APP/Contents/MacOS/Waffle"
# The speech model normally downloads in the app's first-run setup. A copy in models/ (for development) goes inside the app instead;
# on APFS `cp -c` makes a clone that takes no extra space.
if [ -f "$MODEL" ]; then
  cmp -s "$MODEL" "$APP/Contents/Resources/$(basename "$MODEL")" || cp -c "$MODEL" "$APP/Contents/Resources/" 2>/dev/null || cp "$MODEL" "$APP/Contents/Resources/"
fi

ICONSET=$(mktemp -d)/AppIcon.iconset && mkdir "$ICONSET"
cp assets/icon.png "$ICONSET/icon_512x512@2x.png"
for s in 16 32 128 256 512; do
  sips -z $s $s "$ICONSET/icon_512x512@2x.png" --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
  sips -z $((s * 2)) $((s * 2)) "$ICONSET/icon_512x512@2x.png" --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"

# BuildPath: apps started from Finder get a bare PATH, so Waffle looks for `claude` in the PATH of the shell that built it.
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>Waffle</string>
  <key>CFBundleDisplayName</key><string>Waffle</string>
  <key>CFBundleIdentifier</key><string>io.github.oufinx.waffle</string>
  <key>CFBundleExecutable</key><string>Waffle</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.3.0</string>
  <key>LSMinimumSystemVersion</key><string>15.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSMicrophoneUsageDescription</key><string>Waffle transcribes your side of the meeting. Audio never leaves this Mac.</string>
  <key>BuildPath</key><string>$PATH</string>
</dict></plist>
PLIST
# Sign with the local certificate from make-signing-identity.sh if there is one, so macOS keeps the app's permissions across
# rebuilds; otherwise ad-hoc (permissions then have to be granted again after each build).
if security find-certificate -c "Waffle Local Signing" >/dev/null 2>&1; then
  codesign --force --deep -s "Waffle Local Signing" "$APP"
else
  codesign --force --deep -s - "$APP"
fi
echo "built: $APP"
