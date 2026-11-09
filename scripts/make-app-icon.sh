#!/bin/bash
# 앱 아이콘 PNG를 다시 만듭니다 (M6(3)). 그림은 Sources/OfficeStage/Art/AppIconArt.swift에 있습니다.
#
#   scripts/make-app-icon.sh      (make icon)
#
# 1) office-sim icon → build/icon/app-icon-full.svg, app-icon-small.svg
# 2) scripts/render-icon.swift로 macOS 아이콘 크기(16~512 @1x/@2x)의 PNG를
#    App/Assets.xcassets/AppIcon.appiconset/에 씁니다. 16·32px 칸은 선을 굵게 하고 세부를 덜어 낸 small을 씁니다.
# 만든 PNG는 Git에 올립니다 (앱 빌드에 Swift 패키지 실행이 필요 없게).
set -euo pipefail
cd "$(dirname "$0")/.."

SWIFT=${SWIFT:-swift}
SVG_DIR=build/icon
SET=App/Assets.xcassets/AppIcon.appiconset

$SWIFT run -q office-sim icon --out "$SVG_DIR" >/dev/null
mkdir -p "$SET"

# 이름  픽셀  그림
while read -r name pixels detail; do
    $SWIFT scripts/render-icon.swift "$SVG_DIR/app-icon-$detail.svg" "$pixels" "$SET/$name.png"
    echo "$SET/$name.png ($pixels px, $detail)"
done <<'LIST'
icon_16x16 16 small
icon_16x16@2x 32 small
icon_32x32 32 small
icon_32x32@2x 64 full
icon_128x128 128 full
icon_128x128@2x 256 full
icon_256x256 256 full
icon_256x256@2x 512 full
icon_512x512 512 full
icon_512x512@2x 1024 full
LIST
