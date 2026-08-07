#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

swift build -c release --disable-sandbox

APP_NAME="Tools UI.app"
APP="$ROOT/$APP_NAME"
BIN="$ROOT/.build/release/ToolsUI"
ICON_ICNS="$ROOT/Resources/AppIcon.icns"
ICON_PNG="$ROOT/Resources/AppIcon-256.png"
if [[ ! -f "$ICON_PNG" && -f "$ROOT/Resources/AppIcon.iconset/icon_256x256.png" ]]; then
	ICON_PNG="$ROOT/Resources/AppIcon.iconset/icon_256x256.png"
fi

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleDevelopmentRegion</key>
	<string>en</string>
	<key>CFBundleExecutable</key>
	<string>ToolsUI</string>
	<key>CFBundleIdentifier</key>
	<string>dev.toolsui.app</string>
	<key>CFBundleInfoDictionaryVersion</key>
	<string>6.0</string>
	<key>CFBundleName</key>
	<string>Tools UI</string>
	<key>CFBundleDisplayName</key>
	<string>Tools UI</string>
	<key>CFBundlePackageType</key>
	<string>APPL</string>
	<key>CFBundleShortVersionString</key>
	<string>1.0.0</string>
	<key>CFBundleVersion</key>
	<string>1</string>
	<key>LSMinimumSystemVersion</key>
	<string>14.0</string>
	<key>NSHighResolutionCapable</key>
	<true/>
	<key>CFBundleIconFile</key>
	<string>AppIcon</string>
</dict>
</plist>
PLIST

cp "$BIN" "$APP/Contents/MacOS/ToolsUI"
chmod +x "$APP/Contents/MacOS/ToolsUI"

if [[ -f "$ICON_ICNS" ]]; then
	cp "$ICON_ICNS" "$APP/Contents/Resources/AppIcon.icns"
fi
if [[ -f "$ICON_PNG" ]]; then
	cp "$ICON_PNG" "$APP/Contents/Resources/AppIcon-256.png"
fi

rm -rf "$ROOT/ToolsUI.app" 2>/dev/null || true

INSTALL_DIR="${HOME}/Applications"
mkdir -p "$INSTALL_DIR" 2>/dev/null || true
rm -rf "$INSTALL_DIR/ToolsUI.app" 2>/dev/null || true
if rm -rf "$INSTALL_DIR/$APP_NAME" 2>/dev/null; cp -R "$APP" "$INSTALL_DIR/$APP_NAME" 2>/dev/null; then
	/usr/bin/touch "$INSTALL_DIR/$APP_NAME" 2>/dev/null || true
	echo "Installed: $INSTALL_DIR/$APP_NAME"
	echo "Raycast: type “Tools UI” (or run: open -a \"Tools UI\")"
else
	echo "Built: $APP"
	echo "Install for Raycast (run in Terminal):"
	echo "  rm -rf \"\$HOME/Applications/Tools UI.app\" \"\$HOME/Applications/ToolsUI.app\""
	echo "  cp -R \"$APP\" \"\$HOME/Applications/Tools UI.app\""
	echo "  open -a \"Tools UI\""
fi
