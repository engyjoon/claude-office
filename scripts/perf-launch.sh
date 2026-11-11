#!/bin/bash
# 성능 측정용으로 앱을 띄웁니다 (설계서 §8.3, M6(1), 개선 10)
#
#   scripts/perf-launch.sh isolated   설치된 앱을 끄고, 실제 세션의 훅이 섞이지 않게 다시 띄움 + 앱 안 계측 켬
#   scripts/perf-launch.sh normal     설치된 앱을 평소대로 다시 띄움 (isolated 측정이 끝나면 꼭 실행)
#
#   나란히 재기 (설치된 앱은 그대로 두고 새 빌드를 따로 띄움, 개선 10 2단계):
#   scripts/perf-launch.sh side-prepare   make app으로 만든 앱을 build/perf/Claude Office Perf.app으로 복사하고
#                                         번들 ID를 com.engyjoon.claudeoffice.perf로 바꿔 다시 서명 (설정·알림을 설치된 앱과 나눔)
#   scripts/perf-launch.sh side           그 앱을 격리 엔드포인트·계측과 함께 띄우고 PID를 build/perf/side.pid에 적음
#                                         (CLAUDE_OFFICE_BAKE_SCALE이 있으면 넘김: 예 background=1)
#   scripts/perf-launch.sh side-stop      side로 띄운 그 PID만 끝냄
#   재기: PERF_PID=$(cat build/perf/side.pid) scripts/perf.sh <상황>, 창 조작도 PERF_PID=… scripts/perf-window.sh <동작>
#
# isolated·side: 엔드포인트 파일을 build/perf/endpoint에 써서, Claude Code 훅 스크립트(기본 엔드포인트 파일을 읽음)는
# 그 앱으로 가지 않습니다. isolated는 연결이 거부되어 바로 끝나고(항상 exit 0), side는 설치된 앱이 그대로 받습니다.
# 데스크톱 앱에 열린 세션은 파일에서 읽어 쉬는 중으로 앉습니다. 바쁜 상황은 scripts/perf-busy.sh로 이 엔드포인트에 보냅니다.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="/Applications/Claude Office.app"
ENDPOINT="$ROOT/build/perf/endpoint"
BUILT="$ROOT/build/DerivedData/Build/Products/Release/Claude Office.app"
SIDE_APP="$ROOT/build/perf/Claude Office Perf.app"
SIDE_EXEC="$SIDE_APP/Contents/MacOS/Claude Office"
SIDE_ID="com.engyjoon.claudeoffice.perf"
SIDE_PID_FILE="$ROOT/build/perf/side.pid"
mkdir -p "$ROOT/build/perf"

# side로 띄운 앱의 PID (살아 있고 실행 파일이 SIDE_EXEC일 때만)
side_pid() {
    [[ -f "$SIDE_PID_FILE" ]] || return 1
    local pid
    pid="$(cat "$SIDE_PID_FILE")"
    [[ "$pid" =~ ^[0-9]+$ ]] || return 1
    [[ "$(ps -o comm= -p "$pid" 2>/dev/null || true)" == "$SIDE_EXEC" ]] || return 1
    echo "$pid"
}

case "${1:-}" in
    isolated)
        pkill -f "Claude Office.app/Contents/MacOS" 2>/dev/null || true
        sleep 1
        open -n --env CLAUDE_OFFICE_ENDPOINT="$ENDPOINT" --env CLAUDE_OFFICE_PERF=1 "$APP"
        echo "격리 실행: 엔드포인트 $ENDPOINT, 계측 ~/Library/Logs/Claude Office/perf.log" ;;
    normal)
        pkill -f "Claude Office.app/Contents/MacOS" 2>/dev/null || true
        sleep 1
        open "$APP"
        echo "평소대로 실행했어요." ;;
    side-prepare)
        [[ -d "$BUILT" ]] || { echo "빌드한 앱이 없어요: make app" >&2; exit 1; }
        if side_pid >/dev/null; then echo "나란히 띄운 앱이 실행 중이에요: scripts/perf-launch.sh side-stop" >&2; exit 1; fi
        rm -rf "$SIDE_APP"
        cp -R "$BUILT" "$SIDE_APP"
        plutil -replace CFBundleIdentifier -string "$SIDE_ID" "$SIDE_APP/Contents/Info.plist"
        plutil -replace CFBundleName -string "Claude Office Perf" "$SIDE_APP/Contents/Info.plist"
        plutil -replace CFBundleDisplayName -string "Claude Office Perf" "$SIDE_APP/Contents/Info.plist"
        codesign --force --deep --sign - "$SIDE_APP" >/dev/null 2>&1
        codesign --verify "$SIDE_APP"
        echo "준비: $SIDE_APP (번들 ID $SIDE_ID)" ;;
    side)
        [[ -d "$SIDE_APP" ]] || { echo "먼저 scripts/perf-launch.sh side-prepare" >&2; exit 1; }
        if pid="$(side_pid)"; then echo "이미 실행 중이에요 (PID $pid)" >&2; exit 1; fi
        args=(--env CLAUDE_OFFICE_ENDPOINT="$ENDPOINT" --env CLAUDE_OFFICE_PERF=1)
        [[ -n "${CLAUDE_OFFICE_BAKE_SCALE:-}" ]] && args+=(--env CLAUDE_OFFICE_BAKE_SCALE="$CLAUDE_OFFICE_BAKE_SCALE")
        open -n "${args[@]}" "$SIDE_APP"
        # 띄운 프로세스를 실행 파일 경로로 찾습니다 (설치된 앱은 경로가 달라 섞이지 않음)
        for _ in $(seq 1 20); do
            for pid in $(pgrep -f "Claude Office Perf.app/Contents/MacOS/" || true); do
                if [[ "$(ps -o comm= -p "$pid" 2>/dev/null || true)" == "$SIDE_EXEC" ]]; then
                    echo "$pid" >"$SIDE_PID_FILE"
                    echo "나란히 실행: PID $pid, 엔드포인트 $ENDPOINT, 계측 ~/Library/Logs/Claude Office/perf.log"
                    exit 0
                fi
            done
            sleep 0.5
        done
        echo "띄운 앱의 PID를 찾지 못했어요" >&2
        exit 1 ;;
    side-stop)
        if pid="$(side_pid)"; then
            kill "$pid"
            echo "끝냄: PID $pid"
        else
            echo "side로 띄운 앱이 실행 중이 아니에요" >&2
        fi
        rm -f "$SIDE_PID_FILE" ;;
    *) sed -n '2,17p' "$0" | sed 's/^# \{0,1\}//'; exit 1 ;;
esac
