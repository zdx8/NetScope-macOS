#!/bin/bash
# 把 SwiftPM 产物组装成可双击运行的 .app。
# 用法：bash Scripts/build_app.sh [--no-open] [--dmg]
set -euo pipefail

APP_NAME="NetScope"
BUNDLE_ID="com.zdx8.netscope"
APP_VERSION="1.1.2"
MIN_MACOS="14.0"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

OPEN_AFTER=1
MAKE_DMG=0
for argument in "$@"; do
  case "$argument" in
    --no-open) OPEN_AFTER=0 ;;
    --dmg) MAKE_DMG=1 ;;
    *) echo "未知参数：$argument" >&2; exit 2 ;;
  esac
done

DIST="$ROOT/dist"
APP_DIR="$DIST/${APP_NAME}.app"
BUILD_NUMBER="$(date +%y%m%d.%H%M)"

echo "==> 1/5 编译（release）"
swift build -c release --disable-sandbox
BIN="$ROOT/.build/release/${APP_NAME}"
if [ ! -f "$BIN" ]; then
  echo "找不到构建产物：$BIN" >&2
  exit 1
fi

echo "==> 2/5 应用图标"
ICNS="$ROOT/Resources/AppIcon.icns"
ICON_SRC="$ROOT/Scripts/make_icon.swift"
# 判据带上源文件时间戳：只判断「文件是否存在」会让改了配色后仍沿用旧图标
if [ ! -f "$ICNS" ] || [ "$ICON_SRC" -nt "$ICNS" ]; then
  ICONSET="$ROOT/.build/AppIcon.iconset"
  mkdir -p "$ICONSET"
  swiftc -O -o "$ROOT/.build/make-icon" "$ICON_SRC"
  "$ROOT/.build/make-icon" "$ICONSET"
  iconutil -c icns "$ICONSET" -o "$ICNS"
  echo "    已重新生成 AppIcon.icns"
else
  echo "    复用现有图标"
fi

echo "==> 3/5 组装 bundle"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"
cp -f "$BIN" "$APP_DIR/Contents/MacOS/${APP_NAME}"
cp -f "$ICNS" "$APP_DIR/Contents/Resources/AppIcon.icns"

# 用不带引号的 heredoc 做变量插值，版本号只维护在脚本顶部一处
cat > "$APP_DIR/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleDevelopmentRegion</key><string>zh_CN</string>
	<key>CFBundleExecutable</key><string>${APP_NAME}</string>
	<key>CFBundleIdentifier</key><string>${BUNDLE_ID}</string>
	<key>CFBundleName</key><string>${APP_NAME}</string>
	<key>CFBundleDisplayName</key><string>${APP_NAME}</string>
	<key>CFBundleIconFile</key><string>AppIcon</string>
	<key>CFBundlePackageType</key><string>APPL</string>
	<key>CFBundleShortVersionString</key><string>${APP_VERSION}</string>
	<key>CFBundleVersion</key><string>${BUILD_NUMBER}</string>
	<key>LSMinimumSystemVersion</key><string>${MIN_MACOS}</string>
	<key>LSUIElement</key><true/>
	<key>NSHighResolutionCapable</key><true/>
	<key>NSPrincipalClass</key><string>NSApplication</string>
</dict>
</plist>
PLIST

echo "==> 4/5 临时签名"
codesign --force --sign - --timestamp=none "$APP_DIR"

echo "==> 5/5 校验"
echo "    架构      : $(lipo -archs "$APP_DIR/Contents/MacOS/${APP_NAME}")"
echo "    Bundle ID : $(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP_DIR/Contents/Info.plist")"
echo "    版本      : $(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP_DIR/Contents/Info.plist") ($(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP_DIR/Contents/Info.plist"))"
echo "    体积      : $(du -sh "$APP_DIR" | awk '{print $1}')"
codesign --verify --strict "$APP_DIR" && echo "    签名      : 有效"

# ASCII 哨兵：确认改动真的进了产物（中文 grep 不可靠，不能用来做这个判断）
if grep -aq "$BUNDLE_ID" "$APP_DIR/Contents/MacOS/${APP_NAME}"; then
  echo "    二进制内已包含 bundle id 哨兵"
else
  echo "    警告：二进制里找不到 bundle id 哨兵，产物可能不是本次构建" >&2
fi

if [ "${SKIP_ICON_CACHE_REFRESH:-0}" != "1" ]; then
  touch "$APP_DIR" "$ICNS"
  /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$APP_DIR" >/dev/null 2>&1 || true
fi

if [ "$MAKE_DMG" = "1" ]; then
  DMG="$DIST/${APP_NAME}-${APP_VERSION}-arm64.dmg"
  echo "==> 打包 DMG"
  rm -f "$DMG"
  hdiutil create -volname "$APP_NAME" -srcfolder "$APP_DIR" -ov -format UDZO "$DMG" >/dev/null
  echo "    $DMG ($(du -sh "$DMG" | awk '{print $1}'))"
fi

echo ""
echo "完成：$APP_DIR"
if [ "$OPEN_AFTER" = "1" ]; then
  pkill -x "$APP_NAME" 2>/dev/null || true
  sleep 0.3
  open "$APP_DIR"
  echo "已启动，请留意菜单栏右侧的图标。"
fi
