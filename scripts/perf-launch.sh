#!/bin/bash
# 성능 측정용으로 설치된 앱을 다시 띄웁니다 (설계서 §8.3, M6(1))
#
#   scripts/perf-launch.sh isolated   실제 세션의 훅이 섞이지 않게 띄움 + 앱 안 계측 켬
#   scripts/perf-launch.sh normal     평소대로 다시 띄움 (측정이 끝나면 꼭 실행)
#
# isolated: 엔드포인트 파일을 build/perf/endpoint에 써서, Claude Code 훅 스크립트(기본 엔드포인트 파일을 읽음)는
# 연결이 거부되어 바로 끝납니다(항상 exit 0, Claude Code에는 영향 없음). 그동안 실제 세션 활동은 사무실에 나오지 않고,
# 데스크톱 앱에 열린 세션은 파일에서 읽어 쉬는 중으로 앉습니다. 바쁜 상황은 scripts/perf-busy.sh로 이 엔드포인트에 보냅니다.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="/Applications/Claude Office.app"
ENDPOINT="$ROOT/build/perf/endpoint"
mkdir -p "$ROOT/build/perf"

pkill -f "Claude Office.app/Contents/MacOS" 2>/dev/null || true
sleep 1
case "${1:-}" in
    isolated)
        open -n --env CLAUDE_OFFICE_ENDPOINT="$ENDPOINT" --env CLAUDE_OFFICE_PERF=1 "$APP"
        echo "격리 실행: 엔드포인트 $ENDPOINT, 계측 ~/Library/Logs/Claude Office/perf.log" ;;
    normal)
        open "$APP"
        echo "평소대로 실행했어요." ;;
    *) sed -n '2,10p' "$0" | sed 's/^# \{0,1\}//'; exit 1 ;;
esac
