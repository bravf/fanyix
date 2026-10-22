#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
swift build -c release --product Shurufa
app="$PWD/dist/FanyiX.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
mkdir -p .build/icon-assets
swiftc Sources/Shurufa/AppIcon.swift scripts/generate-icon.swift -o .build/icon-assets/generate-icon
.build/icon-assets/generate-icon .build/icon-assets/FanyiX.iconset
iconutil -c icns .build/icon-assets/FanyiX.iconset -o "$app/Contents/Resources/FanyiX.icns"
cp .build/release/Shurufa "$app/Contents/MacOS/Shurufa"
cp -R .build/release/Shurufa_TranslationCore.bundle "$app/Contents/Resources/"
cat > "$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleExecutable</key><string>Shurufa</string>
  <key>CFBundleIdentifier</key><string>local.shurufa.translator</string>
  <key>CFBundleName</key><string>FanyiX</string>
  <key>CFBundleDisplayName</key><string>FanyiX</string>
  <key>CFBundleIconFile</key><string>FanyiX</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.5.18</string>
  <key>CFBundleVersion</key><string>25</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSAccessibilityUsageDescription</key><string>读取选中文字并将翻译结果替换到原输入框。</string>
</dict></plist>
PLIST
signing_identity="${CODE_SIGN_IDENTITY:--}"
codesign --force --sign "$signing_identity" --identifier local.shurufa.translator "$app"
codesign --verify --deep --strict "$app"
if [[ "$signing_identity" == "-" ]]; then
  echo "注意：当前使用临时签名，重新构建后可能需要移除旧的辅助功能条目并重新授权。可通过 CODE_SIGN_IDENTITY 指定已安装的代码签名身份。"
fi
ditto -c -k --sequesterRsrc --keepParent "$app" "$PWD/dist/FanyiX.zip"
echo "已构建：$app"
echo "下载包：$PWD/dist/FanyiX.zip"
