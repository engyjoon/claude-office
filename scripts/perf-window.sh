#!/bin/bash
# 측정용 창 조작 (손쉬운 사용 권한 필요: System Events). 사용자가 직접 해도 됩니다.
#   scripts/perf-window.sh open      메뉴바 메뉴의 "사무실 보기" (메뉴 첫 버튼)
#   scripts/perf-window.sh close     사무실 창 닫기 (미니가 켜져 있으면 미니가 나타남)
#   scripts/perf-window.sh mini      사무실 창의 "미니 사무실로" (미니를 켜고 사무실 창을 닫음)
#   scripts/perf-window.sh mini-off  미니의 ✕ (미니 끄기)
#   scripts/perf-window.sh minimize  사무실 창 최소화
#   scripts/perf-window.sh restore   최소화 풀기
#   scripts/perf-window.sh list      앱 창 목록
set -euo pipefail
TITLE="Claude Office 사무실"
run() { osascript -e "tell application \"System Events\" to tell process \"Claude Office\" to $1"; }
case "${1:-list}" in
    open)
        # 앱이 막 켜졌으면 메뉴가 늦게 뜨므로 창이 보일 때까지 몇 번 다시 시도합니다
        for _ in 1 2 3 4 5; do
            osascript -e 'tell application "System Events" to tell process "Claude Office"
                click menu bar item 1 of menu bar 2
                delay 1.5
                click button 1 of group 1 of window 1
            end tell' >/dev/null 2>&1 || true
            sleep 1
            if run "get name of every window" | grep -q "$TITLE"; then
                # 메뉴 창을 닫고, 사무실 창을 주 화면으로 (메뉴바 아이콘을 누른 화면에 열리면 보이지 않는 화면일 수 있음)
                osascript -e 'tell application "System Events" to key code 53' >/dev/null 2>&1 || true
                run "set position of window \"$TITLE\" to {80, 80}" >/dev/null 2>&1 || true
                exit 0
            fi
            osascript -e 'tell application "System Events" to key code 53' >/dev/null 2>&1 || true
        done
        echo "사무실 창을 열지 못했어요. 메뉴바 아이콘 → 사무실 보기를 눌러 주세요." >&2
        exit 1 ;;
    mini) run "click (first button of toolbar 1 of window \"$TITLE\" whose description is \"미니 사무실로\")" ;;
    mini-off) run "click (first button of window \"Claude Office 미니 사무실\")" ;;
    close) run "click (first button of window \"$TITLE\" whose subrole is \"AXCloseButton\")" ;;
    minimize) run "set value of attribute \"AXMinimized\" of window \"$TITLE\" to true" ;;
    restore) run "set value of attribute \"AXMinimized\" of window \"$TITLE\" to false" ;;
    list) run "get name of every window" ;;
    *) echo "모르는 동작: $1" >&2; exit 1 ;;
esac
