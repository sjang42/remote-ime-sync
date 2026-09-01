#!/bin/bash
# 유니버설 빌드 → RemoteIMESync.app 번들 → ad-hoc 서명 → zip
# bare 실행파일은 TCC 가 신원을 못 잡아 입력 모니터링 목록에 안 뜬다. 번들 + 서명 필요.
set -euo pipefail
cd "$(dirname "$0")/.."
VER="${1:?usage: make-app.sh <version>}"
swift build -c release --arch x86_64 --arch arm64 --product RemoteIMESync

OUT=packaging/build
rm -rf "$OUT" && mkdir -p "$OUT/RemoteIMESync.app/Contents/MacOS"
APP="$OUT/RemoteIMESync.app"
cp .build/apple/Products/Release/RemoteIMESync "$APP/Contents/MacOS/RemoteIMESync"
cat > "$APP/Contents/Info.plist" <<PL
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>RemoteIMESync</string>
  <key>CFBundleDisplayName</key><string>RemoteIMESync</string>
  <key>CFBundleIdentifier</key><string>com.jex.remote-ime-sync</string>
  <key>CFBundleExecutable</key><string>RemoteIMESync</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VER</string>
  <key>CFBundleVersion</key><string>$VER</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><true/>
</dict></plist>
PL
# Developer ID 로 서명한다 — ad-hoc 은 빌드마다 cdhash 가 바뀌어 TCC 권한이
# 매번 초기화된다(입력 모니터링·손쉬운 사용을 새 버전마다 다시 켜야 함).
SIGN_ID="${SIGN_ID:-Developer ID Application: Sanghyun Jang}"
if security find-identity -v -p codesigning | grep -q "$SIGN_ID"; then
    codesign --force --options runtime --timestamp \
        --sign "$SIGN_ID" --identifier com.jex.remote-ime-sync "$APP"
else
    echo "warning: '$SIGN_ID' 없음 — ad-hoc 서명으로 대체 (버전마다 권한 재승인 필요)" >&2
    codesign --force --sign - --identifier com.jex.remote-ime-sync "$APP"
fi
codesign -dv "$APP" 2>&1 | grep -E "Identifier|Signature"
(cd "$OUT" && zip -qry RemoteIMESync.app.zip RemoteIMESync.app)
echo "→ $OUT/RemoteIMESync.app.zip"
