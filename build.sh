#!/bin/zsh
set -euo pipefail
cd "${0:A:h}"
BUILD_DIR="${TMPDIR:-/tmp}/deng-monitor-build"
APP="${DENG_APP_PATH:-dist/邓眼瞎.app}"
mkdir -p "$BUILD_DIR" "$APP/Contents/MacOS" "$APP/Contents/Resources"
swiftc -O -swift-version 6 -module-cache-path "$BUILD_DIR/module-cache" -o "$APP/Contents/MacOS/DENG-monitor" -import-objc-header Support/CIOReport/include/IOReport.h -Xlinker -undefined -Xlinker dynamic_lookup Sources/SiliconMonitor/*.swift
MACMON="$(command -v macmon || true)"
if [[ -z "$MACMON" && -x /opt/homebrew/bin/macmon ]]; then MACMON=/opt/homebrew/bin/macmon; fi
if [[ -z "$MACMON" ]]; then print '请先安装采集器：brew install macmon'; exit 1; fi
if [[ -f "$APP/Contents/Resources/macmon" ]]; then chmod u+w "$APP/Contents/Resources/macmon"; fi
cp "$MACMON" "$APP/Contents/Resources/macmon"
MACMON_LICENSE="${MACMON:A:h:h}/LICENSE"
if [[ ! -f "$MACMON_LICENSE" ]]; then print '未找到 macmon 的许可证，请使用 Homebrew 安装 macmon 后重试。'; exit 1; fi
cp "$MACMON_LICENSE" "$APP/Contents/Resources/macmon-LICENSE"
cp Support/SiliconScope-LICENSE "$APP/Contents/Resources/SiliconScope-LICENSE"
cp Support/Assets/Silicon.icns "$APP/Contents/Resources/Silicon.icns"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>DENG-monitor</string>
<key>CFBundleIdentifier</key><string>local.silicon.monitor</string>
<key>CFBundleIconFile</key><string>Silicon.icns</string>
<key>CFBundleName</key><string>邓眼瞎</string>
<key>CFBundleDisplayName</key><string>邓眼瞎</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>1.3.0</string>
<key>CFBundleVersion</key><string>5</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>LSUIElement</key><false/>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
mkdir -p "$APP/Contents/Resources/en.lproj" "$APP/Contents/Resources/zh-Hans.lproj"
cat > "$APP/Contents/Resources/en.lproj/InfoPlist.strings" <<'STRINGS'
"CFBundleDisplayName" = "DENG-monitor";
"CFBundleName" = "DENG-monitor";
STRINGS
cat > "$APP/Contents/Resources/zh-Hans.lproj/InfoPlist.strings" <<'STRINGS'
"CFBundleDisplayName" = "邓眼瞎";
"CFBundleName" = "邓眼瞎";
STRINGS
codesign --force --sign - "$APP/Contents/Resources/macmon"
codesign --force --sign - "$APP"
print "已生成：${APP:A}"
