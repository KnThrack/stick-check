#!/bin/zsh
# Builds a release binary and wraps it in a double-clickable Stick Check.app (ad-hoc signed, local use only).
set -euo pipefail
cd "$(dirname "$0")"

swift build -c release
app="build/Stick Check.app"
mkdir -p "$app/Contents/MacOS"
cp .build/release/StickCheck "$app/Contents/MacOS/StickCheck"
cat > "$app/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>StickCheck</string>
    <key>CFBundleIdentifier</key><string>local.stickcheck</string>
    <key>CFBundleName</key><string>Stick Check</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
EOF
codesign --force --sign - "$app"
echo "Built $PWD/$app"
