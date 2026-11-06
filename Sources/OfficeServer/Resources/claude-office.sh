#!/bin/sh
# Claude Office 훅 스크립트 (설계서 §4.2)
#
# Claude Code가 훅마다 넘겨주는 JSON을 Claude Office 앱의 로컬 서버(127.0.0.1)로 보냅니다.
# - 아무것도 출력하지 않습니다. (SessionStart/UserPromptSubmit 훅의 stdout은 대화 컨텍스트에 추가되기 때문)
# - 앱이 꺼져 있거나 응답이 없어도 기다리지 않고 바로 끝납니다. 항상 exit 0.
# - 앱이 실행될 때마다 endpoint 파일에 "포트 토큰"을 기록합니다.
ENDPOINT_FILE="${CLAUDE_OFFICE_ENDPOINT:-$HOME/Library/Application Support/ClaudeOffice/endpoint}"
if [ ! -r "$ENDPOINT_FILE" ]; then
  cat >/dev/null
  exit 0
fi
read -r PORT TOKEN < "$ENDPOINT_FILE"
payload=$(cat)
( printf '%s' "$payload" | curl -s -m 1 -X POST \
    -H "Content-Type: application/json" \
    -H "X-Office-Token: $TOKEN" \
    -H "X-Office-Term: ${TERM_PROGRAM:-unknown}" \
    --data-binary @- "http://127.0.0.1:$PORT/v1/hook" >/dev/null 2>&1 & )
exit 0
