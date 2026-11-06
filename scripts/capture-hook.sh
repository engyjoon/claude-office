#!/bin/sh
# Claude Office M0 — 훅 페이로드 수집기
#
# Claude Code 훅이 넘겨주는 JSON을 이벤트마다 파일 하나로 저장합니다.
# - 아무것도 출력하지 않습니다. (SessionStart/UserPromptSubmit 훅의 stdout은 대화 컨텍스트에 추가되기 때문)
# - 어떤 경우에도 exit 0으로 끝나서 Claude Code 작업을 막지 않습니다.
# - 원본은 사용자 홈의 ~/claude-office-capture/raw/ 에만 남고, 어디로도 전송되지 않습니다.
DIR="$HOME/claude-office-capture/raw"
mkdir -p "$DIR" 2>/dev/null || { cat >/dev/null; exit 0; }
NAME="$(date +%Y%m%d-%H%M%S)-$$"
{
  printf '{"captured_at":"%s","term_program":"%s","payload":' "$(date +%Y-%m-%dT%H:%M:%S%z)" "${TERM_PROGRAM:-}"
  cat
  printf '}\n'
} > "$DIR/$NAME.json" 2>/dev/null
exit 0
