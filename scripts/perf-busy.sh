#!/bin/bash
# 바쁜 상황(c)용 부하: 위임 시나리오(Scenarios/delegation.jsonl, 출근·타이핑·위임·보고)의 앞 60초를 2배속으로 되풀이해 보냅니다.
#   scripts/perf-busy.sh [초=90]
# perf-launch.sh isolated로 띄웠으면 그 엔드포인트로, 아니면 기본 엔드포인트로 보냅니다.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DURATION="${1:-90}"
ENDPOINT="$ROOT/build/perf/endpoint"
[[ -f "$ENDPOINT" ]] && ARGS=(--endpoint "$ENDPOINT") || ARGS=()
cd "$ROOT"
swift build -q --product office-sim
SIM="$(swift build --show-bin-path)/office-sim"
SCENARIO="$ROOT/build/perf/busy.jsonl"
# 위임 시나리오의 60초까지만 (그 뒤는 한참 조용함)
awk '/^#/ { next } { if (match($0, /"t": [0-9.]+/)) { t = substr($0, RSTART + 5, RLENGTH - 5) + 0; if (t <= 60) print } }' \
    Scenarios/delegation.jsonl >"$SCENARIO"
end=$((SECONDS + DURATION))
while ((SECONDS < end)); do
    "$SIM" replay "$SCENARIO" --speed 2 "${ARGS[@]}" >/dev/null || sleep 1
done
