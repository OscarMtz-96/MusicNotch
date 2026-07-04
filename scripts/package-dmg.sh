#!/usr/bin/env bash
set -euo pipefail

APP_NAME="Music Visualizer"
EXECUTABLE_NAME="MusicVisualizer"
BUNDLE_ID="com.oscarmartinez.musicvisualizer"
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
DIST_DIR="$ROOT_DIR/dist"
ASSET_DIR="$ROOT_DIR/Assets"
APP_PATH="$DIST_DIR/$APP_NAME.app"
DMG_ROOT="$DIST_DIR/dmg-root"
DMG_PATH="$DIST_DIR/$APP_NAME.dmg"
TMP_DMG="$DIST_DIR/$APP_NAME.tmp.dmg"
MOUNT_DIR="$DIST_DIR/mount"
ICON_PATH="$DIST_DIR/AppIcon.icns"
BACKGROUND_PATH="$ASSET_DIR/dmg-background.png"

cd "$ROOT_DIR"
swift package resolve
python3 - <<'PY'
from pathlib import Path

path = Path(".build/checkouts/mediaremote-adapter/Sources/MediaRemoteAdapter/MediaController.swift")
path.chmod(path.stat().st_mode | 0o200)
text = path.read_text()
old = '''    private var perlScriptPath: String? {
        guard let path = Bundle.module.path(forResource: "run", ofType: "pl") else {
            assertionFailure("run.pl script not found in bundle resources.")
            return nil
        }
        return path
    }'''
new = '''    private var perlScriptPath: String? {
        if let resourcePath = Bundle.main.resourceURL?
            .appendingPathComponent("MediaRemoteAdapter_MediaRemoteAdapter.bundle/run.pl")
            .path,
            FileManager.default.fileExists(atPath: resourcePath) {
            return resourcePath
        }

        guard let path = Bundle.module.path(forResource: "run", ofType: "pl") else {
            assertionFailure("run.pl script not found in bundle resources.")
            return nil
        }
        return path
    }'''
if old in text:
    path.write_text(text.replace(old, new))
PY
swift build -c release
BUILD_DIR="$(swift build -c release --show-bin-path 2>/dev/null | tail -n 1)"

hdiutil detach "/Volumes/$APP_NAME" >/dev/null 2>&1 || true
hdiutil detach "/Volumes/$APP_NAME 1" >/dev/null 2>&1 || true

rm -rf "$DIST_DIR"
mkdir -p "$APP_PATH/Contents/MacOS" "$APP_PATH/Contents/Frameworks" "$APP_PATH/Contents/Resources" "$DMG_ROOT"

if [ -f "$ASSET_DIR/AppIcon.png" ]; then
  ICONSET="$DIST_DIR/AppIcon.iconset"
  mkdir -p "$ICONSET"
  sips -z 16 16 "$ASSET_DIR/AppIcon.png" --out "$ICONSET/icon_16x16.png" >/dev/null
  sips -z 32 32 "$ASSET_DIR/AppIcon.png" --out "$ICONSET/icon_16x16@2x.png" >/dev/null
  sips -z 32 32 "$ASSET_DIR/AppIcon.png" --out "$ICONSET/icon_32x32.png" >/dev/null
  sips -z 64 64 "$ASSET_DIR/AppIcon.png" --out "$ICONSET/icon_32x32@2x.png" >/dev/null
  sips -z 128 128 "$ASSET_DIR/AppIcon.png" --out "$ICONSET/icon_128x128.png" >/dev/null
  sips -z 256 256 "$ASSET_DIR/AppIcon.png" --out "$ICONSET/icon_128x128@2x.png" >/dev/null
  sips -z 256 256 "$ASSET_DIR/AppIcon.png" --out "$ICONSET/icon_256x256.png" >/dev/null
  sips -z 512 512 "$ASSET_DIR/AppIcon.png" --out "$ICONSET/icon_256x256@2x.png" >/dev/null
  sips -z 512 512 "$ASSET_DIR/AppIcon.png" --out "$ICONSET/icon_512x512.png" >/dev/null
  sips -z 1024 1024 "$ASSET_DIR/AppIcon.png" --out "$ICONSET/icon_512x512@2x.png" >/dev/null
  iconutil -c icns "$ICONSET" -o "$ICON_PATH"
  cp "$ICON_PATH" "$APP_PATH/Contents/Resources/AppIcon.icns"
fi

SIGNED_EXECUTABLE="$DIST_DIR/$EXECUTABLE_NAME.signed"
cp "$BUILD_DIR/$EXECUTABLE_NAME" "$SIGNED_EXECUTABLE"
install_name_tool -add_rpath "@executable_path/../Frameworks" "$SIGNED_EXECUTABLE" 2>/dev/null || true
codesign --remove-signature "$SIGNED_EXECUTABLE" >/dev/null 2>&1 || true
cp "$SIGNED_EXECUTABLE" "$APP_PATH/Contents/MacOS/$EXECUTABLE_NAME"
cp "$BUILD_DIR"/lib*.dylib "$APP_PATH/Contents/Frameworks/" 2>/dev/null || true

if [ -d "$BUILD_DIR/MediaRemoteAdapter_MediaRemoteAdapter.bundle" ]; then
  cp -R "$BUILD_DIR/MediaRemoteAdapter_MediaRemoteAdapter.bundle" "$APP_PATH/Contents/Resources/"
fi

cat > "$APP_PATH/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key>
  <string>en</string>
  <key>CFBundleExecutable</key>
  <string>$EXECUTABLE_NAME</string>
  <key>CFBundleIdentifier</key>
  <string>$BUNDLE_ID</string>
  <key>CFBundleInfoDictionaryVersion</key>
  <string>6.0</string>
  <key>CFBundleName</key>
  <string>$APP_NAME</string>
  <key>CFBundleIconFile</key>
  <string>AppIcon</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>0.1.0</string>
  <key>CFBundleVersion</key>
  <string>1</string>
  <key>LSMinimumSystemVersion</key>
  <string>13.0</string>
  <key>LSUIElement</key>
  <true/>
  <key>NSHighResolutionCapable</key>
  <true/>
</dict>
</plist>
PLIST

xattr -cr "$APP_PATH" 2>/dev/null || true
find "$APP_PATH/Contents/Frameworks" -name "*.dylib" -exec codesign --force --sign - {} \; >/dev/null
chmod -R u+rwX "$APP_PATH"
xattr -cr "$APP_PATH" 2>/dev/null || true
codesign --force --deep --sign - "$APP_PATH" >/dev/null

swift "$ROOT_DIR/scripts/make-dmg-background.swift" "$BACKGROUND_PATH"
hdiutil create -size 90m -fs HFS+ -volname "$APP_NAME" -ov "$TMP_DMG" >/dev/null
MOUNT_OUTPUT="$(hdiutil attach "$TMP_DMG")"
MOUNT_DIR="$(printf '%s\n' "$MOUNT_OUTPUT" | awk '/\/Volumes\// {print substr($0, index($0,"/Volumes/")); exit}')"

cp -R "$APP_PATH" "$MOUNT_DIR/"
ln -s /Applications "$MOUNT_DIR/Applications"
mkdir -p "$MOUNT_DIR/.background"
cp "$BACKGROUND_PATH" "$MOUNT_DIR/.background/dmg-background.png"

osascript <<APPLESCRIPT >/dev/null 2>&1 || true
tell application "Finder"
  tell disk "$APP_NAME"
    open
    delay 1
    set current view of container window to icon view
    set toolbar visible of container window to false
    set statusbar visible of container window to false
    set bounds of container window to {100, 100, 660, 420}
    set theViewOptions to the icon view options of container window
    set arrangement of theViewOptions to not arranged
    set icon size of theViewOptions to 96
    set background picture of theViewOptions to POSIX file "$MOUNT_DIR/.background/dmg-background.png"
    set position of item "$APP_NAME.app" of container window to {150, 160}
    set position of item "Applications" of container window to {410, 160}
    update without registering applications
    delay 2
    close
  end tell
end tell
APPLESCRIPT

for _ in 1 2 3 4 5 6; do
  [ -f "$MOUNT_DIR/.DS_Store" ] && break
  sleep 0.5
done
sync
hdiutil detach "$MOUNT_DIR" >/dev/null
hdiutil convert "$TMP_DMG" -format UDZO -imagekey zlib-level=9 -o "$DMG_PATH" >/dev/null
rm -rf "$DMG_ROOT" "$MOUNT_DIR" "$TMP_DMG"

echo "$DMG_PATH"
