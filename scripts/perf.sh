#!/bin/bash
# Claude Office 성능 측정 (설계서 §8.3, M6(1))
#
# 설치된 앱 프로세스의 CPU%, 메모리(RSS·phys_footprint), 쉬던 CPU를 깨운 횟수(idle wakeups)를
# N초 동안 1초 간격으로 재서 평균과 최댓값을 표 한 줄로 냅니다. 결과는 build/perf/results.md에도 쌓입니다.
#
#   scripts/perf.sh <상황 이름> [초=30]
#   make perf CASE=a DURATION=30
#
# 상황 이름 예 (설계서 §8.3 구현 메모):
#   a  사무실 창 닫힘 + 미니 켬, 모두 쉬는 중
#   b  사무실 창 열림 + 미니 켬, 쉬는 중
#   c  사무실 창 열림, 일하는 중 (다른 터미널에서 scripts/perf-busy.sh)
#   d  사무실 창이 다른 창에 가려짐 또는 최소화
#   e  미니 끔 + 사무실 창 닫힘 (메뉴바만)
#
# 앱 안의 계측(fps·지연)은 기본으로 꺼져 있습니다. 켜려면:
#   defaults write com.engyjoon.claudeoffice debug.perfProbe -bool true   (앱을 다시 켜야 적용)
# 켜 두면 ~/Library/Logs/Claude Office/perf.log에 10초마다 씬별 fps와 훅→화면 지연 백분위가 남고,
# 이 스크립트가 측정 구간의 마지막 줄을 같이 보여 줍니다.
set -euo pipefail

LABEL="${1:-}"
DURATION="${2:-30}"
if [[ -z "$LABEL" ]]; then
    sed -n '2,22p' "$0" | sed 's/^# \{0,1\}//'
    exit 1
fi

PROCESS_PATTERN="Claude Office.app/Contents/MacOS"
PID="$(pgrep -f "$PROCESS_PATTERN" | head -n 1 || true)"
if [[ -z "$PID" ]]; then
    echo "실행 중인 Claude Office를 찾지 못했어요. open \"/Applications/Claude Office.app\"" >&2
    exit 1
fi

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT_DIR="$ROOT/build/perf"
mkdir -p "$OUT_DIR"
RAW="$OUT_DIR/raw-$LABEL-$(date +%Y%m%d-%H%M%S).txt"
PROBE_LOG="$HOME/Library/Logs/Claude Office/perf.log"
probe_before=0
[[ -f "$PROBE_LOG" ]] && probe_before=$(wc -l <"$PROBE_LOG" | tr -d ' ')

chip="$(sysctl -n machdep.cpu.brand_string 2>/dev/null || echo '?')"
echo "측정: 상황 $LABEL, ${DURATION}초, PID $PID ($chip)" >&2

footprint_mb() {
    # phys_footprint (MB). footprint 출력 첫 줄 "Footprint: 161 MB"
    footprint "$1" 2>/dev/null | awk '/Footprint:/ { for (i = 1; i <= NF; i++) if ($i == "Footprint:") { v = $(i + 1); u = $(i + 2) } }
        END { if (u == "KB") v /= 1024; if (u == "GB") v *= 1024; print v + 0 }'
}

fp_start="$(footprint_mb "$PID")"
# top: 첫 표본은 누적값이라 버리고, 그 뒤 1초 간격 표본만 씁니다.
# 열: CPU%, 메모리(RSS 비슷한 값), 쉬던 CPU를 깨운 수(누적)
top -l $((DURATION + 1)) -s 1 -pid "$PID" -stats pid,cpu,mem,idlew >"$RAW"
fp_end="$(footprint_mb "$PID")"

row="$(awk -v pid="$PID" -v label="$LABEL" -v dur="$DURATION" -v fp0="$fp_start" -v fp1="$fp_end" '
    function mb(s,   n, u) { n = s + 0; u = substr(s, length(s)); gsub(/[+-]$/, "", s); u = substr(s, length(s));
        if (u == "K") return n / 1024; if (u == "G") return n * 1024; if (u == "B") return n / 1048576; return n }
    $1 == pid {
        sample++
        if (sample == 1) { w0 = $4 + 0; next }
        cpu = $2 + 0; mem = mb($3); w = $4 + 0
        n++; cs += cpu; if (cpu > cm) cm = cpu
        ms += mem; if (mem > mm) mm = mem
        wl = w
    }
    END {
        if (n == 0) { print "| " label " | 표본 없음 |"; exit }
        printf "| %s | %d초 | %.2f | %.2f | %.0f | %.0f | %.0f → %.0f | %.1f |\n",
            label, dur, cs / n, cm, ms / n, mm, fp0, fp1, (wl - w0) / n
    }' "$RAW")"

header="| 상황 | 길이 | CPU 평균 % | CPU 최대 % | 메모리 평균 MB | 메모리 최대 MB | phys_footprint MB (시작 → 끝) | 깨움/초 |"
sep="|---|---|---|---|---|---|---|---|"
echo "$header"
echo "$sep"
echo "$row"

RESULTS="$OUT_DIR/results.md"
[[ -f "$RESULTS" ]] || { echo "# Claude Office 성능 측정 ($chip)"; echo; echo "$header"; echo "$sep"; } >"$RESULTS"
echo "$row <!-- $(date '+%Y-%m-%d %H:%M') pid $PID -->" >>"$RESULTS"

if [[ -f "$PROBE_LOG" ]]; then
    lines="$(tail -n +$((probe_before + 1)) "$PROBE_LOG" | grep -v '^#' || true)"
    if [[ -n "$lines" ]]; then
        echo
        echo "앱 안 계측 (perf.log, 10초 구간):"
        echo "$lines"
        # 훅이 없고 30fps(active) 구간이 없던 10초 구간만 모은 CPU (다른 세션의 훅이 섞이지 않은 대기 값)
        echo "$lines" | awk '/hook→stage ms n=0 / && !/active/ { for (i = 1; i <= NF; i++) if ($i == "cpu") { v = $(i + 1); sub(/%/, "", v); s += v; n++; if (v > m) m = v } }
            END { if (n) printf "조용한 구간 %d개: 앱 CPU 평균 %.2f%%, 최대 %.2f%%\n", n, s / n, m; else print "조용한 구간 없음 (측정 중 훅이 계속 들어옴)" }'
    fi
fi
echo >&2
echo "원자료: $RAW" >&2
