#!/bin/bash
# OpenCUA build script — compiles the Swift helper and assembles the
# "OpenCUA Helper.app" bundle that holds the macOS TCC permissions.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DIST="$ROOT/dist"
APP="$DIST/OpenCUA Helper.app"
BIN_DIR="$APP/Contents/MacOS"
HELPER="$ROOT/swift/.build/release/opencua-helper"

echo "==> Building Swift helper..."
cd "$ROOT/swift"
swift build -c release --disable-sandbox

echo "==> Assembling app bundle..."
rm -rf "$APP"
mkdir -p "$BIN_DIR"
cp "$HELPER" "$BIN_DIR/opencua-helper"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>              <string>OpenCUA Helper</string>
    <key>CFBundleDisplayName</key>       <string>OpenCUA Helper</string>
    <key>CFBundleIdentifier</key>        <string>com.opencua.helper</string>
    <key>CFBundleExecutable</key>        <string>opencua-helper</string>
    <key>CFBundlePackageType</key>       <string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.1.0</string>
    <key>CFBundleVersion</key>           <string>1</string>
    <key>LSUIElement</key>               <true/>
    <key>LSMinimumSystemVersion</key>    <string>13.0</string>
    <key>NSHighResolutionCapable</key>   <true/>
    <key>NSAccessibilityUsageDescription</key>
    <string>OpenCUA 需要辅助功能权限来读取界面元素并模拟鼠标键盘操作（不移动你的真实光标）。</string>
    <key>NSScreenCaptureUsageDescription</key>
    <string>OpenCUA 需要屏幕录制权限来截取应用窗口截图供 AI 感知界面。</string>
    <key>NSAppleEventsUsageDescription</key>
    <string>OpenCUA 通过 Apple Events 启动应用程序。</string>
</dict>
</plist>
PLIST

echo "==> Ad-hoc code signing with stable identifier (required for TCC persistence)..."
# Use --identifier so TCC tracks the permission by bundle id rather than the
# volatile cdhash — this way rebuilds don't invalidate Accessibility/Screen
# Recording permissions.
codesign --force --sign - --identifier com.opencua.helper "$APP" >/dev/null 2>&1 || codesign --force -s - "$APP"

echo "==> Symlinking CLI (optional)..."
mkdir -p "$DIST/bin"
ln -sf "$ROOT/server/cua.mjs" "$DIST/bin/cua" 2>/dev/null || true

echo "==> Build complete:"
echo "    $APP"
echo "    CLI:     node $ROOT/server/cua.mjs <command>"
echo "    MCP:     node $ROOT/server/opencua-mcp.mjs"
