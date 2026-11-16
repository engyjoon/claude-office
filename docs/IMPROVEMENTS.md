# 개선 목록

2026-11-11 전체 검토(코드·디자인·사용성)에서 나온 개선 사항입니다. 위에서 아래로 추천 순서이고, 항목마다 새 세션 하나가 맡습니다.

- **확인 수준**: "재현"·"실측"은 직접 돌려 본 것, "코드"는 코드를 읽어 추적한 것, "전제 미확인"은 Claude Code나 macOS의 동작을 전제로 한 것입니다. 맡은 세션은 고치기 전에 전제를 먼저 확인합니다.
- **상태**: 대기 → 진행 중 → 완료(커밋) / 보류(까닭).
- 모델은 항목의 성격으로 골랐습니다: 상태 기계·구조를 다시 짜는 일은 Fable 5.2, 범위가 정해진 버그 묶음은 Opus 5.5, 작은 수정과 문구는 Sonnet 5.5.

## 한눈에 보기

| # | 항목 | 추천 모델 (노력도) | 상태 | 결과 |
|---|---|---|---|---|
| 1 | 훅 버전 감지·연동 진단 | Opus 5.5 (medium) | 완료(커밋) | 알려진 경로로 버전 감지, 빠진 이벤트·`disableAllHooks`·관리 설정 진단, 배너·연동 탭 표시. 화면 확인 필요 |
| 2 | 질문·계획 승인 기록 닫기 | Sonnet 5.5 (medium) | 완료(커밋) | 끝날 때 열린 `.permission` 항목도 닫고, 끝난 뒤 문구는 "질문 답함"·"계획 승인함" |
| 3 | 비밀값 가림 순서·규칙 | Sonnet 5.5 (medium) | 완료(커밋) | 300자로 먼저 자르고 → 가리고 → 경로 줄이고 → 40자. 빈칸 구분은 `--플래그 값`만, `curl -u`·`sshpass -p`·`mysql -p값`·`Authorization: Basic` 추가 |
| 4 | 끝 이벤트 없는 턴·도구·세션 복구 | Fable 5.2 (high) | 완료(커밋) | 암묵적 종료 규칙(설계서 §5.3): idle_prompt·새 요청·1시간 침묵으로 턴 닫기, 2초 넘게 떨어진 Pre는 새 묶음, 서브의 승인 알림은 서브에게, 끝난 세션 30초 기억, 출근 중 10초. 터미널 세션의 시간 기반 퇴근은 넣지 않음(선택지는 결과에). 화면 확인 필요 |
| 5 | 행 머무름·화면 밖 서브 신호 | Opus 5.5 (high) | 완료(커밋) | 보이던 행은 쉬거나 45초 조용할 때만 밀려남(승인 대기 숨은 행은 바로), 숨은 서브의 신호를 거둬 메인이 하이파이브 없이 바로 진행, 미니 초점 전환 때 다른 행의 퇴근자 치움, 남은 신호 지움, 길찾기 격자는 묶음당 한 번·장애물이 같으면 그대로. 화면 확인 필요 |
| 6 | 조용한 실패 없애기·첫 실행 안내 | Opus 5.5 (medium) | 완료(커밋) | 알림 권한을 보내기 직전에 다시 읽고 켤 때·끌 때 알림 지움, 이동 판정을 `SessionDestination` 하나로(모르는 터미널은 버튼 없음, `openApplication`), `HookAlert`로 메뉴 배너·사무실 창 띠·메뉴바 아이콘에 고장 표시와 설치 결과, 첫 실행 환영 창. Cursor 구별 불가·미니에는 안 넣음. 화면 확인 필요 |
| 7 | 훅 서버·설정 파일 안전 (+ 죽은 터미널 세션 퇴근) | Opus 5.5 (medium) — 범위가 늘어 Sonnet 5.5에서 올림 (훅 스크립트·서버·앱에 걸친 PID 확인) | 완료(커밋) | 엔드포인트 파일은 rename·자기 것만 지움·가로채이면 빨간 경고, settings.json 링크는 대상에 쓰고 바뀐 것 없으면 안 씀, 백업 5개, 핸들러 단위 제거. 서버 연결당 3초·동시 32개·accept 쉼·토큰 먼저·거절 수 표시. 훅이 `$PPID`(실측: Claude Code 자신)·`__CFBundleIdentifier`를 보내 죽은 터미널 세션 퇴근과 Cursor 구별. 훅당 추가 시간은 측정 오차 안. 다시 설치 필요, 화면 확인 필요 |
| 8 | 화면 디자인 다듬기 | Opus 5.5 (high) | 완료(커밋) | 칩은 제 머리 위 자기 몫(옆 사람까지 거리 절반)으로 말줄임·옆으로 안 밀고 위로, 마우스 올림·고름만 전체. 밤 ♪·Zz·빛줄기·외침 선은 따뜻한 흰색. 같은 폴더 행 표지에 세션 제목 둘째 줄. 답변 필요만 남으면 메뉴바 파란 점. 승인 대기·쉼·정리 중인 메인엔 보고 연출 생략. NFC·grapheme 폭. 종이비행기 15°. 소파는 좌표 정상. 화면 확인 필요 |
| 9 | 문구·경과 시간·잔손질 | Sonnet 5.5 (medium) | 완료(커밋) | 경과 시간 글자·갱신 일정을 코어 `ElapsedText` 한 벌로(앱 사본 삭제, 일 단위까지), 낡은 문구·용어 통일(사무실 창 열기), Return 키 수식키, 테스트 이벤트는 테스트 세션 훅만 셈, `make install`/`uninstall`은 실행 중이면 멈춤·빌드 오류 보임, 로그는 맨 아래일 때만 따라감, 미니 자리는 당겨 넣음. 화면 확인 필요 |
| 10 | 레티나 메모리 줄이기 | Opus 5.5 (high) | 완료(커밋) | 1단계: 창 배율로 굽기·배율 바뀌면 다시 굽기, 캐시 400장·32MiB에서 오래된 것부터, 층별 배율 자리. 2단계 실측(5K 2배율, 화면 잠긴 상태): 큰 원인은 바탕을 GPU로 굽던 화면 밖 SKView(약 113MB)와 안 보이는 장면의 굽기 → 뷰 없으면 안 굽고 모두 CoreGraphics로(투명도 층 자르기로 굽기 15~33ms). 메뉴바만 196→19MB, 미니 205→31MB, 사무실 창 299→117MB. 목표 1배율 150MB / 2배율 200MB. 보이는 상태는 화면 확인 필요 |
| 11 | 구조 정리와 안전망 | Fable 5.2 (high) | 완료(커밋) | 잠복 버그 둘(테스트), 죽은 코드 제거, 무대 쪽 중복 합침, 배치 숫자는 `OfficeLayout`에서만(접근 지점 불변식 테스트), 모습 규칙은 `Choreographer.look(for:)` 하나(어긋난 곳은 일할 때 모습으로), `AppModel.commit` 하나(tick이 상태를 바꾸면 바로 반영)·훅 한 번 파싱, `make test` CI 워크플로, 큰 파일 둘 나눔. 스냅샷은 모습 규칙의 3장만 달라짐. 글자 폭 두 벌·`OverlayTier`는 그대로 둠(까닭은 결과에). 화면 확인 필요 |

## 모든 항목에 공통인 규칙

- 고치기 전에 해당 코드를 읽고 문제가 실제로 있는지 확인합니다. 없거나 전제가 틀렸으면 고치지 않고 이 문서에 까닭을 적습니다.
- 동작을 바꾸면 테스트를 함께 넣습니다. `make test`가 통과해야 하고, `App/`을 고쳤으면 `make app`으로 빌드까지 확인합니다.
- `make install`·`make run`·`make serve`는 하지 않습니다. 실행 중인 `/Applications/Claude Office.app`을 끄거나 바꾸지 않고, `~/.claude` 아래는 건드리지 않습니다.
- 설계서에 적힌 동작이 바뀌면 `docs/DESIGN.md`의 해당 절에 한두 줄로 적습니다.
- 끝나면 위 표의 상태·결과와 아래 항목의 "결과"를 채웁니다. 맥 화면에서 확인이 필요한 것은 "화면 확인 필요"로 남깁니다.
- 항목 범위 밖의 문제를 발견하면 고치지 않고 맨 아래 "새로 발견한 것"에 적습니다.

---

## 1. 훅 버전 감지·연동 진단

**문제 (재현)**: 이 맥의 `~/.claude/settings.json`에는 Claude Office 훅이 기본 9종만 등록돼 있습니다. Claude Code는 2.1.321이라 확장 5종(SubagentStart, PermissionRequest, PermissionDenied, PostToolUseFailure, StopFailure)도 들어가야 합니다.

- `ClaudeVersionDetector.detect`가 `$SHELL -lc "claude --version"`을 쓰는데, GUI 앱 환경(PATH가 `/usr/bin:/bin:/usr/sbin:/sbin`)의 로그인 zsh는 `~/.zshrc`를 읽지 않아 `~/.local/bin/claude`를 못 찾습니다. `env -i HOME=$HOME PATH=/usr/bin:/bin:/usr/sbin:/sbin /bin/zsh -lc 'claude --version'`으로 재현됩니다. (`Sources/OfficeServer/HookInstaller.swift:147`)
- `HookInstaller.status()`는 이벤트가 하나라도 있으면 `.installed`라서, 설정 → 연동이 "설치됨"으로 계속 초록입니다. Claude Code를 올린 뒤에도 마찬가지입니다. (`HookInstaller.swift:74`, `Sources/OfficeServer/HookHealth.swift:74`)
- `disableAllHooks`나 관리 설정(`allowManagedHooksOnly`)으로 훅이 막혀 있어도 "아직 받은 이벤트가 없어요"만 보입니다. (`HookHealth.swift:120`)

**고칠 방향**

- 셸보다 먼저 알려진 경로(`~/.local/bin/claude`, `/opt/homebrew/bin/claude`, `/usr/local/bin/claude`)를 찾아 직접 실행합니다.
- 등록된 이벤트와 `recommendedEvents(for:)`를 비교해, 모자라면 "다시 설치"를 권하는 상태(메뉴 배너와 설정 → 연동)를 냅니다. 버전을 못 알아냈을 때는 경고하지 않습니다.
- `settings.json`의 `disableAllHooks`를 읽어 구체적인 오류 문구를 보여 줍니다. 관리 설정 파일은 읽을 수 있을 때만 확인합니다.
- `ClaudeVersion(parsing:)`이 로그인 배너의 다른 버전 문자열을 집지 않게 합니다.

**완료 기준**: GUI 환경을 흉내 낸 테스트에서 버전을 찾고, 9종만 등록된 설정을 넣으면 다시 설치를 권합니다. 설치 자체(파일 쓰기)는 사용자가 앱에서 누릅니다.

**결과**: 완료 (2026-11-11). 문제 세 가지를 모두 재현으로 확인한 뒤 고쳤습니다.

- **버전 감지**: `ClaudeVersionDetector`가 `~/.local/bin/claude` → `~/.claude/local/claude` → `/opt/homebrew/bin/claude` → `/usr/local/bin/claude` → PATH 순으로 직접 실행하고, 없을 때만 로그인 셸을 씁니다. `env -i … PATH=/usr/bin:/bin:/usr/sbin:/sbin ~/.local/bin/claude --version`이 `2.1.321 (Claude Code)`를 내는 것을 확인했습니다.
- **버전 읽기**: `ClaudeVersion(parsing:)`은 "Claude Code"가 든 줄의 x.y.z(낱말 전체가 버전일 때만)를 받고, 표지가 없으면 버전으로 시작하는 마지막 줄만 받습니다. "nvm 0.39.7"·"zsh 5.9.0"·"node v20.11.1" 같은 배너를 집지 않습니다.
- **빠진 이벤트**: `HookSettingsEditor.missingEvents(installed:version:)`과 `HookHealth.missingEvents`. 기본 9종만 있고 버전이 2.1.318 이상이면 "settings.json 등록"이 경고("5개 빠짐 (…)")가 되고 머리줄이 "다시 설치"를 권합니다. 버전을 모르면 따지지 않습니다. 메뉴 배너도 같은 경우 "다시 설치" 버튼을 보여 줍니다. 앱은 켤 때·메뉴를 열 때·연동 탭을 볼 때 버전을 확인하되 10분에 한 번만 다시 실행합니다(Claude Code 자동 업데이트를 잡으려고).
- **막힌 훅**: `HookBlocker`(`disableAllHooks`는 사용자·관리 설정, `allowManagedHooksOnly`는 관리 설정만). `HookInstaller.blocker()`가 `~/.claude/settings.json`, `/Library/Application Support/ClaudeCode/managed-settings.json`, `managed-settings.d/*.json`을 읽을 수 있을 때만 읽습니다. 연동 탭 머리줄이 오류와 구체적인 문구, 항목에 "훅 실행"이 붙고, 메뉴에도 빨간 배너가 뜹니다. 두 키가 2.1.321 실행 파일에 있는 것은 확인했고, `managed-settings.d` 폴더는 Claude Code 문서를 따른 것입니다(이 맥에는 관리 설정이 없음).
- 테스트: `HookSettingsEditorTests`(배너 섞인 버전 읽기, 빠진 이벤트, 막는 설정), `HookHealthTests`(GUI PATH를 흉내 낸 임시 홈의 가짜 `~/.local/bin/claude`를 셸 없이 찾음, 기본 9종 + 2.1.321 → 다시 설치 권함, 막힘 문구, 관리 설정 파일 읽기). `make test` 411개 통과, `make app` 빌드 성공.
- **화면 확인 필요**: 이 맥에서 새로 빌드한 앱을 켜면 메뉴 배너("Claude Code 2.1.321에서 받을 수 있는 이벤트 5개가 빠져 있어요" + 다시 설치)와 연동 탭 경고가 보여야 합니다. 설치된 앱은 바꾸지 않았으므로 실제 "다시 설치"는 사용자가 새 앱을 설치한 뒤 누릅니다.

## 2. 질문·계획 승인 기록 닫기

**문제 (코드)**: `AskUserQuestion`·`ExitPlanMode`는 `permissionAsked` 비트만 내서 기록에 `.permission(call)` 항목이 생깁니다. 끝날 때(`toolEnded`) `openToolIndex`는 `toolCall != nil`인 `.tool` 항목만 찾으므로 새 항목을 덧붙이고 `.permission` 항목은 열린 채 남습니다. 계획을 승인한 뒤에도 현황 줄이 "계획 승인 대기 (20분째)"이고, 인스펙터 타임라인과 "[화면 밖]" 알림 줄에도 남습니다.

- `Sources/OfficeCore/Model/ActivityJournal.swift:67-78`, `:138-143`
- 보이는 곳: `Sources/OfficeCore/Model/StatusLine.swift:275`, `:306-310`

**고칠 방향**: `toolEnded`에서 같은 id·이름의 열린 `.permission` 항목도 닫습니다(또는 질문 도구를 `.awaitingPermission` 상태의 `.tool` 항목으로 기록).

**완료 기준**: 질문에 답한 뒤와 계획 승인 뒤의 기록·현황 줄 테스트가 있습니다.

**결과**: 문제가 코드에 있음을 실패하는 테스트로 확인했습니다(고치기 전: 답한 뒤에도 "질문 답 대기 (6분째)", "계획 승인 대기 (19분째)"). `ActivityJournal.openToolIndex`에 `includePermission`을 더해 `toolEnded`가 같은 id·이름의 열린 `.permission(call)` 항목을 닫습니다(덧붙인 항목 없음). 닫힌 뒤에도 문구가 "대기"로 남지 않도록 `StatusLine`은 질문 도구가 열려 있을 때만 대기 문구를 쓰고 끝나면 "질문 답함"·"계획 승인함"(실패·거부는 도구 이름 + 결과)으로 씁니다. 일반 도구의 Pre → PermissionRequest → Post는 그대로(테스트 추가). 타임라인·"[화면 밖]" 알림 줄도 같은 기록을 읽어 함께 바로잡힙니다. 테스트: `StatusLineTests`, `AgentTimelineTests`. `make test` 414개 통과.

## 3. 비밀값 가림 순서·규칙

**문제 (코드)**

- `commandSummary`가 명령을 40자로 자른 뒤 `makeCall`이 가립니다. `export DB_URL=postgres://admin:S3cretPassw0rd@db/x`는 `@`가 잘려 `postgres://admin:S3cretPa…`로 칩·현황 줄·알림에 나옵니다. (`Sources/OfficeCore/Model/ToolCall.swift:89`, `:128-132`)
- 키워드 규칙의 구분자 `[=: ]`가 빈칸도 받아서 `pwd && ls`가 "pwd <가림> ls"가 되고, `kubectl get secret foo`·`grep -r secret src/`도 다음 낱말을 잃습니다. (`Sources/OfficeCore/Dialogue/Redactor.swift:19`)
- 놓치는 것: `curl -u user:pass`, `sshpass -p …`, `mysql -p…`, `Authorization: Basic …`.
- `shortenPaths`가 자르기 전에 첫 줄 전체에 정규식 두 개를 돌립니다(1MB 입력이면 메인 스레드에서 오래 걸림). (`ToolCall.swift:128-164`)

**고칠 방향**: 첫 줄을 몇백 자로 먼저 자르고 → 가리고 → 경로를 줄이고 → 40자로 자릅니다. 키워드 뒤 빈칸은 `--flag` 꼴일 때만 구분자로 받고, 위의 놓치는 꼴에 규칙을 더합니다.

**완료 기준**: 위 예들이 테스트로 들어 있고, 기존 `Redactor`·`ToolCall` 테스트가 그대로 통과합니다.

**결과**: 고치기 전에 새 테스트가 실패하는 것을 확인했습니다.
- `commandSummary`: 첫 줄 → 300자 → 공백 정리 → `Redactor` → `shortenPaths` → 40자. Grep·Glob·WebSearch·Agent의 `subject`도 `ToolCatalog.clean`으로 자르기 전에 가립니다. `HookParser`의 오류 문구는 가린 뒤 자르는 순서가 이미 맞습니다.
- 키워드 규칙은 `=`·`:` 구분자만 받고, 빈칸 구분은 `--password xxx`처럼 `--플래그` 꼴(다음 낱말이 `-`로 시작하면 값이 아님)에서만 받습니다. `pwd && ls`, `kubectl get secret foo`, `grep -r secret src/`, `gh auth token | pbcopy`는 그대로 나옵니다.
- 추가 규칙: `curl -u/--user user:pass`(값에 `:`가 있을 때만, `git push -u origin`은 그대로), `sshpass -p`, `mysql*` 명령 안의 `-p값`(붙여 쓴 꼴은 `mysql` 계열 명령일 때만 가림 — 일반 `-p<값>`은 `mkdir -p`·`ssh -p22` 같은 오탐이 커서 뺌), `Authorization: Basic`.
- 알려진 한계: Swift `Regex`가 lookbehind를 지원하지 않아 `(?:^|\s)` 접두를 쓰고 그 접두는 그대로 되살립니다. `mysql … | tool -pxxx`처럼 파이프 뒤의 꼴은 못 가립니다.

## 4. 끝 이벤트 없는 턴·도구·세션 복구

**문제 (코드, 일부 전제 미확인)**: 바쁜 상태가 모두 끝 이벤트(Stop, PostToolUse, SubagentStop, SessionEnd)가 와야 풀립니다. 시간 제한이나 암묵적 종료 규칙은 압축(compaction)에만 있습니다.

- **Stop 없이 끝난 턴**: 사용자가 Esc로 중단하면 메인이 다음 요청까지 `.thinking`·`.working`·`.waitingForPermission`으로 남습니다("생각 중 (3시간째)", 초록 점, 승인 알림). `idle_prompt`가 오면 상태는 `.waitingForInput`이 되지만 연출은 그대로이고, `promptSubmitted`는 `turnEnded`처럼 남은 서브를 정리하지 않습니다. (`Sources/OfficeCore/Model/OfficeState.swift:123-133`, `:227-248`, `Sources/OfficeCore/Engine/Choreographer.swift:305-312`) — 전제 미확인: 중단 때 Stop·SubagentStop 훅이 오는지. `Tests/OfficeCoreTests/Fixtures`와 `docs/DESIGN.md` §4.1에서 먼저 확인합니다.
- **PostToolUse가 빠진 도구**: Pre(A)만 오고 Post(A)가 안 오면, 그 뒤 도구가 끝날 때마다 `runningTools.last`인 A가 되살아납니다. (`OfficeState.swift:146-149`, `:165`)
- **서브의 승인 요청이 메인에 붙음**: `agent_id` 없는 `Notification(permission_prompt)`이 메인을 `.waitingForPermission(nil)`로 만들고, 서브의 도구가 끝나도 메인은 안 풀립니다. (`OfficeState.swift:186-218`) — 전제 미확인: 서브가 낸 알림의 실제 모양.
- **끝나지 않는 세션**: SessionEnd를 못 받은 터미널 세션(kill -9), SubagentStop을 못 받은 백그라운드 서브는 영원히 남습니다. 끝난 세션 id를 기억하지 않아, SessionEnd 뒤 늦게 온 훅이 새 메인을 만듭니다. (`OfficeState.swift:106-110`, `:353-394`)
- `.arriving`이 다른 상태로 넘어가지 않아 "출근 중"이 몇 시간 남습니다. (`OfficeState.swift:746`)
- 알림 계획의 세션 키가 세션 id가 바뀔 때(`continueHostSession`) 옮겨지지 않습니다. (`Sources/OfficeCore/Model/NotificationPlanner.swift:80-85`)

**고칠 방향**: `OfficeState`에 "암묵적 종료" 규칙을 한 곳에 둡니다. 쉬지 않는 메인에 `waitingForInput`이 오거나 새 `promptSubmitted`가 오면 앞 턴이 끝난 것으로 보고(도구 비우기, 포그라운드 서브 정리, 기록 닫기, 쉬는 모습), 새 Pre가 오면 그 전 묶음의 남은 도구를 버리고, 끝난 세션 id를 잠깐 기억합니다. 터미널 세션의 시간 기반 퇴근은 설계서 §5.2가 일부러 두지 않았으므로, 넣는다면 아주 긴 시간이나 수동 "퇴근"으로 하고 설계서에 적습니다.

**완료 기준**: 위 경우마다 리듀서·연출 테스트가 있고, 기존 404개 테스트가 통과합니다.

**결과**: 완료 (2026-11-11). 규칙은 설계서 §5.3에 표로 적었습니다.

전제 확인 (실제 중단을 수집해 보지는 못했고, Claude Code 훅 문서와 2.1.321 실행 파일의 코드로 확인):

- **확인**: Esc 중단에는 `Stop`이 오지 않습니다(문서). 돌던 도구를 취소해도 `PostToolUse`·`PostToolUseFailure`가 오지 않습니다(문서). `Notification`에는 `agent_id`가 없습니다(실행 파일: 알림의 공통 필드에 서브에이전트 정보를 넘기지 않음. 수집 픽스처 `Notification-1·2`에도 없음). `permission_prompt` 알림은 승인 창이 뜨고 6초 뒤에 옵니다(실행 파일).
- **새로 알게 된 것**: 실패한 도구는 `PostToolUseFailure`로만 끝나서, 기본 9종만 설치된 이 맥에서는 **실패한 도구마다** 끝 이벤트가 없습니다. "되살아나는 도구"가 드문 경우가 아니었습니다.
- **전제 미확인** (오든 안 오든 맞게 설계): 중단된 서브에이전트의 `SubagentStop`(보내는 코드는 있음), 중단 뒤의 `idle_prompt`(문서는 "응답이 끝나고 60초쯤 뒤"만 말함), 일하는 도중 보낸 메시지의 `UserPromptSubmit` 시점(데스크톱 앱은 돌던 턴을 멈추고 답한다는 설명이 실행 파일에 있음).

고친 것:

- **Stop 없이 끝난 턴** — 쉬지 않는 세션에 `idle_prompt`나 새 요청이 오면 앞 턴을 닫습니다(`OfficeState.abandonTurn` → `Beat.turnAbandoned`): 남은 도구 비우기, 포그라운드 서브는 보고 없이 퇴근, 기록 닫기, 승인 대기·알림 풀기, 쉬는 상태. 사용자가 멈춘 턴이라 "확인 안 함"·"답변 필요"·응답 완료 알림·축하 연출은 없습니다. 연출은 칩·⏳·💡·외침 풍선을 거두고 자기 책상에 앉아 그때부터 쉼 단계를 밟습니다. 방금 온 요청(3초 안)보다 늦게 도착한 `idle_prompt`와 서브에이전트 안에서 난 `UserPromptSubmit`은 턴 신호로 치지 않습니다.
- **1시간 침묵** — `idle_prompt`도 새 요청도 없는 경우(kill -9, 중단 뒤 알림이 안 옴)를 위해, 세션 전체에 훅이 1시간 없으면 바쁜 턴을 닫고 1시간 조용한 서브(백그라운드 포함)는 퇴근시킵니다(`expireSilence`, tick). 누군가 승인·질문 답을 기다리는 세션은 건드리지 않습니다. 1시간은 판단으로 고른 값입니다(`OfficeState.silenceLimit`): 실제로 써 보고 중단 뒤 `idle_prompt`가 오지 않는 것으로 드러나면 줄일 수 있습니다.
- **PostToolUse가 빠진 도구** — 그 사람의 앞 `PreToolUse`로부터 2초 넘게 지나서 온 `PreToolUse`는 새 묶음으로 보고 남은 도구를 버립니다(`beginTool`). 병렬 도구(이어서 오는 Pre)와 백그라운드 위임은 그대로입니다. 버린 도구의 기록은 "닫힘"이 됩니다(`ActivityJournal.closeStale`). 묶음 경계는 추정이라, 2초 넘게 떨어져 온 같은 묶음의 병렬 도구는 일찍 버려질 수 있습니다(그 도구가 끝나면 기록은 정상으로 닫힘).
- **서브의 승인 요청** — `agent_id` 없는 `permission_prompt`는 그 세션에서 가장 최근에 도구를 시작해 아직 끝내지 않은 사람에게 그 도구와 함께 붙입니다. 이미 누가 기다리는 중이면 넘깁니다(확장 훅이 있을 때 `PermissionRequest` → 6초 뒤 알림). 그래서 메인이 `.waitingForPermission(nil)`로 남지 않고, 서브의 도구가 끝나면 풀립니다. 병렬 서브가 여럿이면 주인을 틀릴 수 있습니다.
- **끝난 세션** — SessionEnd 뒤 30초 안에 온 그 세션의 훅은 버립니다(64개까지 기억). `SessionStart`·새 요청이거나 데스크톱 목록에서 다시 앉힌 세션이면 받아들입니다.
- **출근 중** — 10초 뒤 세션은 쉬는 중(쉰 시간은 출근 때부터), 서브는 생각 중(`settleArrivals`, tick). 앱을 턴 도중에 켜서 첫 훅이 도구의 끝이면 바로 생각 중.
- **알림의 세션 키** — `NotificationPlanner`의 응답 완료·답변 필요 기록을 세션 id가 아니라 세션 직원(`AgentID`)으로 찾습니다. `continueHostSession`으로 id가 바뀌어도 사람은 그대로라 옮길 것이 없습니다.
- 함께 고친 것: 정리 중에 온 `idle_prompt`가 서류 정리 자세를 남기던 것(압축부터 풉니다), 응답이 끝난 뒤 늦게 온 `PostToolUse`가 쉬는 사람을 생각하는 모습으로 바꿔 쉬러 가지 않던 것(`Choreographer`).

넣지 않은 것 — **SessionEnd를 못 받은 터미널 세션의 퇴근**: 훅만으로는 죽은 세션과 열어 둔 채 쉬는 세션을 가릴 수 없고, §5.2가 "오래 쉬어서 퇴근"을 두지 않은 까닭(며칠씩 열어 두는 세션이 흔함)이 터미널 세션에도 같습니다. 죽은 세션은 이제 바쁜 채로 남지는 않지만(1시간 뒤 쉬는 중) 자리에는 앱을 다시 켤 때까지 남습니다. 선택지는 아래 셋이었고, **사용자가 1번(PID 확인)을 골라 7번 항목에 넣었습니다** (2026-11-11):

1. 훅 스크립트가 Claude Code의 PID를 실어 보내고 앱이 살아 있는지 확인 (가장 정확. `claude-office.sh`·`OfficeServer`, 7번 항목과 겹침)
2. 메뉴·인스펙터에 수동 "퇴근" (앱 화면, 8·9번 쪽)
3. 데스크톱 id가 없는 세션이 N일 조용하면 퇴근 (가장 간단. 쉬는 세션도 사라졌다가 다음 훅에 다시 출근함)

테스트: `OfficeStateTests`(새 묶음 `ImplicitEndTests` 22개), `ChoreographerTests`(`ImplicitEndChoreographyTests` 8개), `NotificationPlannerTests`(3개), `SessionCueTests`·`ResidentTests`(각 1개). 고치기 전 코드에 돌리면 35개 중 28개가 실패하고 나머지 7개는 "지금처럼 동작"을 지키는 테스트입니다. `make test` 453개 통과(418 + 35). `make demo` 출력은 전과 같고, `make snapshot`의 SVG 14장도 전과 바이트까지 같습니다.

- 기존 테스트 하나를 고쳤습니다: `RoomTests.lateHintMerges`가 위임 중인 세션에 `UserPromptSubmit`으로 힌트를 실어 보냈는데, 이제 그 요청이 앞 턴을 닫아 서브가 퇴근하므로 다른 훅(`PreCompact`)으로 바꿨습니다.
- `Scenarios/mini.jsonl`도 같은 까닭으로 메인1의 서브 5명을 백그라운드 위임으로 바꿨습니다(60초의 다음 요청 뒤에도 남아야 65초 그림이 나옴).
- **화면 확인 필요**: (1) 일하는 도중 Esc로 멈추고 1분쯤 뒤 그 세션이 쉬는 모습·"입력 대기"로 바뀌는지 — 안 바뀌면 중단 뒤에는 `idle_prompt`가 오지 않는 것이라 다음 요청이나 1시간 규칙으로만 풀립니다. (2) 서브에이전트가 승인을 요청할 때 메인이 아니라 그 서브가 손을 들고, 승인하면 풀리는지. (3) tick에서만 바뀐 상태(출근 중 → 쉬는 중, 1시간 규칙)는 앱의 명단·현황 줄에 최대 5초 늦게 보입니다(아래 "새로 발견한 것").

## 5. 행 머무름·화면 밖 서브 신호

**문제 (코드)**

- **행이 계속 바뀜**: `FloorPlan.make`가 최근 활동 순 3행을 고르는데 머무름 규칙이 없습니다. 바쁜 행이 4개 이상이면 숨은 행에 훅이 올 때마다 보이는 행이 통째로 교체되고(한 팀은 바로 사라지고 다른 팀은 문에서 걸어 들어옴), 그때마다 길찾기 격자를 다시 만들고 가구를 다시 굽습니다. (`Sources/OfficeStage/OfficeFloor.swift:78-109`, `Tests/OfficeStageTests/FloorTests.swift:156-188`은 지금 동작을 고정해 둠)
- **화면 밖 서브의 보고**: `OfficeFloor`가 숨은 서브의 지시를 버릴 때 `.signal`도 버려서, 메인의 `.await("report:<id>")`가 8초 시간 제한까지 대기열을 막고, 그 뒤 아무도 없는 곳에 하이파이브를 합니다. 숨은 서브 여럿이 잇달아 끝나면 미니의 메인 칩이 수십 초 늦습니다. (`OfficeFloor.swift:205-216`, `Sources/OfficeStage/Stage.swift:352-355`, `Sources/OfficeCore/Engine/Choreographer.swift:399-409`)
- **미니가 다른 행을 보여 줌**: 보여 주던 행에 퇴근 중인 사람이 남아 있을 때 초점이 바뀌면, 닫히는 행이 0번을 차지해 새 행이 띠 아래로 내려갑니다. (`OfficeFloor.swift:255-275`, `Stage.swift:498-503`)
- 늦게 온 `report:` 신호가 `signals`에 영원히 남습니다. (`Stage.swift:166`, `:350`)
- 책상이 하나 늘 때마다 길찾기 격자를 다시 만들고 걷는 사람 전부의 길을 다시 찾습니다. (`Stage.swift:393-401`, `:536-597`)

**고칠 방향**: `make`에 이전 계획을 넘겨, 보이는 행은 쉬고 있거나 30~60초 조용할 때만 밀려나게 합니다(승인 대기·답변 필요가 있는 숨은 행은 바로 올림). 버려진 `.signal`은 전역 지시로 넘기거나 짝이 되는 `.await`와 축하 연출을 함께 뺍니다. 띠 모드에서는 고르지 않은 행의 퇴근 중인 사람을 바로 치웁니다. 배치 갱신은 `enqueue` 끝에 한 번만 합니다.

**완료 기준**: 네 행이 번갈아 훅을 보내는 테스트에서 행이 뒤바뀌지 않고, 숨은 서브가 보고해도 메인의 대기열이 막히지 않습니다. `make snapshot` 결과를 눈으로 확인합니다.

**결과**: 완료 (2026-11-11). 다섯 가지 모두 실패하는 테스트로 먼저 재현한 뒤 고쳤습니다(고치기 전: 2분 동안 네 행이 번갈아 훅을 보내면 보이는 행이 훅마다 바뀜, 숨은 서브가 보고하면 메인의 칩이 8초 넘게 그대로이고 혼자 하이파이브, 미니가 새 행을 띠 아래 y 506에 앉힘, 늦은 신호가 남음, 서브 5명이 한 번에 오면 격자를 5번 다시 만듦). 규칙은 설계서 §6.10(행 머무름·화면 밖 서브의 보고·길찾기 격자)과 §10.1(초점이 바뀔 때)에 적었습니다.

- **행 머무름** — `FloorPlan.make(…, previous:, linger:)`. 보이던 행은 머물고 빈자리만 숨은 행으로 채웁니다. 숨은 행은 행의 급함(승인 대기 > 일하는 중·답변 필요 > 쉬는 중·출근 중)과 마지막 활동이 둘 다 앞설 때, 쉬는 행은 바로, 일하는 행은 45초(`FloorPlan.linger`, 30~60초 중 가운데) 넘게 조용할 때만 밀어냅니다. 판단 결과:
  - **승인을 기다리는 숨은 행은 바로 올립니다.** 승인은 일이 멈춘 상태라 놓치면 안 되고, 설계서 §10.2도 "보통은 승인 요청이 그 행의 마지막 활동이 되어 행이 다시 보인다"를 전제로 "[화면 밖]" 알림을 4행 이상이 함께 기다릴 때의 장치로 두었습니다. 승인을 기다리는 보이는 행은 밀려나지 않으므로, 세 행이 모두 기다리면 넷째 행은 "[화면 밖]" 줄로만 보입니다.
  - **답변 필요는 바로 올리지 않습니다.** 답할 때까지 몇 시간씩 남을 수 있어, 바로 올리면 한 번 올라온 행이 계속 자리를 차지합니다. 일하는 행처럼 다뤄 응답이 끝난 직후(마지막 활동)에는 앞서고, 45초 조용하면 밀려날 수 있습니다. 답변 필요는 미니 초점·명단·알림이 따로 알립니다.
  - **출근 중은 쉬는 행으로 칩니다.** 그러지 않으면 새로 연 세션이 출근 10초 동안 "일하는 행"이라 쉬는 행 대신 보이지 않거나, 거꾸로 보이던 쉬는 행을 밀어낸 뒤 자리를 지킵니다.
  - 조용한 시간은 고른 행들의 가장 최근 활동(보통 방금 온 훅)부터 셉니다. `OfficeFloor`는 지시가 올 때만 계획을 다시 세우므로(앱의 `record`는 빈 지시를 넘기지 않음) 시간만 흘러서는 행이 바뀌지 않습니다. 숨은 행이 오래 걸리는 명령 하나만 돌리면 다른 행의 다음 훅까지 숨어 있을 수 있는데, 보통 다른 행의 훅이 곧 와서 실제로는 문제가 되지 않을 것으로 봤습니다.
  - `FloorTests.overflowRows`(156-188)는 다른 행들이 쉬는 중(출근 중 → 쉬는 중)이라 새 규칙에서도 그대로 통과했습니다. 이름과 주석을 새 규칙("쉬는 행 대신")으로 고쳤고, 바쁜 행의 머무름은 새 묶음 `RowStickinessTests`가 고정합니다.
- **화면 밖 서브의 보고** — 짝이 되는 `.await`와 축하 연출을 함께 빼는 쪽을 골랐습니다(신호만 넘기면 메인이 아무도 없는 곳에 하이파이브). 새 지시 `Directive.Action.awaitEnd(name)`가 `await`부터 함께하는 연출의 끝을 표시하고(`Choreographer`의 보고 연출에서 메인의 하이파이브·"고마워요"·엄지 뒤, 아이콘·표정을 되돌리기 전), `Stage.withdraw(signal:)`가 그 신호를 기다리는(기다릴) 사람의 `await`~`awaitEnd`를 건너뜁니다. `OfficeFloor.apply`는 무대에 넘기지 않은 사람의 `.signal`을 모아 거두고, `Stage.remove`(숨겨서 내림)도 아직 보내지 못한 신호를 거둡니다. 시간 제한(8초, `reportAwaitTimeout`)은 그대로 두었습니다: 화면에 있던 서브가 늦게 도착하는 경우에는 지금처럼 기다린 뒤 축하합니다.
- **미니가 다른 행을 보여 줌** — 띠 모드에서 계획에 행이 있으면, 고른 행이 아닌 행의 퇴근하던 사람을 `apply`·`resync`에서 바로 치웁니다(`OfficeFloor.clearLeavingElsewhere`). 사무실 창과, 고른 행이 없어진 띠(세션이 끝나 메인이 걸어 나가는 중)는 그대로 걸어 나갑니다.
- **남은 신호** — `Stage.signals`를 이름 → 보낸 사람으로 바꾸고, 보낸 사람이 퇴장(`despawn`)하거나 숨겨질 때(`remove`) 그 사람의 신호를 지웁니다.
- **길찾기 격자** — `Stage`에 지시 묶음(`beginBatch`/`endBatch`)을 두고 `enqueue`와 `OfficeFloor.apply`·`resync` 전체를 묶었습니다. 묶음 안에서는 배치(`layout`)는 바로 바꾸되 격자와 걷는 사람의 길은 끝에 한 번만 다시 만들고, `Pathfinder.fits`로 크기·장애물이 같으면 격자를 그대로 두고 행과 함께 옮겨진 걷는 사람만 다시 찾습니다. 묶음 안에서 의자에서 일어나 걷기 시작한 사람은 먼저 나올 입구를 기억해 다시 찾을 때도 가구를 뚫고 가지 않습니다(예전 `relayout`은 그 첫 걸음을 빠뜨렸음). 렌더러가 배치가 바뀔 때 가구를 다시 굽는 것은 앱 쪽이라 손대지 않았고, 행 머무름으로 그 횟수 자체가 줄었습니다.
- 테스트(7개 추가, 고치기 전 코드에서 모두 실패): `RowStickinessTests`(네 행이 번갈아 2분 동안 훅을 보내도 행·메인이 그대로 / 쉬면 바로·45초 조용하면 밀려남·숨은 행의 승인 대기는 바로·승인 대기 행은 머묾 / +N 서브의 보고에 메인 칩이 1초 안에 바뀌고 하이파이브 없음), `MiniOfficeTests`(칸 밖 서브의 보고, 퇴근자가 있을 때 초점 전환), `StageTests`(남은 신호 지우기, 서브 5명이 한 번에 와도 격자 한 번·"+N"만 바뀌면 다시 안 만듦). `make test` 460개 통과(453 + 7). `App/`은 고치지 않았습니다.
- **`make snapshot`** (14장): delegation 6장·mini 5장은 바이트까지 같고, **floor 3장이 다릅니다.** 까닭: 이 시나리오는 1~2.5초에 네 세션이 잇달아 요청을 받는데, 고치기 전에는 1.5~7초에 행이 **6번** 바뀌었습니다(메인1·메인2·메인4가 한 번씩 숨었다가 출입문으로 다시 들어오고, 6~7초에는 메인3·메인4가 번갈아). 고친 뒤에는 1.5초에 한 번만 바뀌고 그대로입니다(두 경우 모두 office-sim에 행이 바뀔 때마다 찍는 임시 출력으로 확인). 그래서 30·52·80초 그림에서 **메인4의 표정**(예전: 다시 세워질 때의 생각하는 얼굴 → 지금: 다른 메인들과 같은 웃는 얼굴)과 머리 위 아이콘들의 **흔들림 위상**(y 0.1~3pt)이 다릅니다. 보이는 행(메인1·2·4), "+N", 자리는 같습니다.
  - 시나리오도 하나 고쳤습니다: `Scenarios/floor.jsonl`의 메인3·메인4 요청 시각을 맞바꿈(2.0 ↔ 2.5초). 그대로 두면 새 규칙에서는 마지막에 일을 시작한 메인4가 숨고 메인3이 보여, 시나리오 설명("숨은 메인3이 60초에 퇴근 → 세 행 그대로")과 그림이 달라집니다. 고치기 전 코드에 바꾼 시나리오를 돌린 그림은 원래 그림과 바이트까지 같아(시각 교환 자체는 예전 결과에 영향 없음), 위의 차이는 모두 새 규칙에서 온 것입니다. 머리 주석도 새 규칙으로 고쳤습니다.
  - `make demo`: 보고 연출에 `lead-1: 신호 연출 끝 report:member-2` 한 줄이 늘었습니다(지시 153 → 154개). 그 밖에는 같습니다.
- **화면 확인 필요**: (1) 세션 4개 이상을 함께 돌릴 때 보이는 행이 훅마다 바뀌지 않는지, 쉬는 행·45초 조용한 행 대신 숨은 행이 들어오는지. 45초가 길거나 짧게 느껴지면 `FloorPlan.linger`만 바꾸면 됩니다. (2) 숨은 행이 승인을 요청하면 바로 보이는지. (3) 미니에서 서브가 퇴근하는 중에 초점이 다른 행으로 넘어갈 때 새 행이 띠에 바로 보이는지. (4) 미니에서 칸 밖 서브가 끝날 때 메인이 하이파이브 없이 바로 칩을 바꾸는지.

## 6. 조용한 실패 없애기·첫 실행 안내

**문제 (코드)**

- **알림 권한 캐시**: `Notifier.authorization`은 앱을 켤 때, 자기 요청 뒤, 설정 → 알림 탭이 보일 때만 새로 읽습니다. 처음에 거부했다가 시스템 설정에서 허용해도 알림이 조용히 버려집니다. (`App/Sources/Notifier.swift:45-52`, `:114-126`)
- **세션 이동 판정이 세 벌**: 메뉴는 `term != nil`이면 "터미널로" 버튼을 보여 주지만 `TerminalFocuser`는 7개만 압니다(tmux·zed는 무반응, 도움말은 "tmux을(를) 앞으로"). `vscode`는 VS Code → Insiders → Cursor 순이라 Cursor 세션도 VS Code를 올립니다. 메뉴 경로는 `acknowledge`와 로그를 건너뜁니다. (`Sources/OfficeCore/Model/Roster.swift:115`, `App/Sources/Support.swift:62-110`, `App/Sources/MenuContentView.swift:185-205`)
- **고장이 안 보임**: 서버 실패(`serverState == .failed`)와 훅 미설치는 메뉴 드롭다운 배너에만 나옵니다. 사무실 창·미니·메뉴바 아이콘에는 없어서, 미리 출근한 세션들이 앉아 있으면 멀쩡해 보입니다. 메뉴 배너의 "설치"는 성공·실패 결과를 보여 주지 않습니다. (`App/Sources/MenuContentView.swift:63-81`, `App/Sources/SettingsView.swift:237`)
- **남는 알림**: 앱을 끄거나 다시 설치하면 띄워 둔 "승인 대기" 알림이 알림 센터에 남습니다. (`App/Sources/AppModel.swift:234-239`)
- **첫 실행**: 메뉴바 아이콘만 생기고 안내가 없습니다.
- 작은 것: `willPresent`가 조용히 바꾸는(`isUpdate`) 알림에도 배너를 다시 띄울 수 있고, 쓰지 않는 `.badge` 권한을 요청합니다. (`Notifier.swift:58`, `:181-186`)

**고칠 방향**: 알림을 보낼 때마다(또는 앱이 활성화될 때) 권한을 다시 읽습니다. 이동 판정·문구·동작을 한 타입(`SessionFocuser`)으로 모으고, 모르는 터미널이면 버튼을 숨깁니다. 활성화는 `NSWorkspace.openApplication`으로 합니다. 서버 실패·훅 문제는 사무실 창 위쪽 띠와 메뉴바 아이콘 상태로도 보여 주고, 설치 결과를 배너에 보여 줍니다. 켤 때와 끌 때 자기 알림을 지웁니다. 훅이 없는 첫 실행에는 메뉴 드롭다운(또는 작은 환영 창)을 한 번 엽니다.

**완료 기준**: `make app` 통과. 권한·이동·알림 동작은 "화면 확인 필요"로 적습니다.

**결과** (2026-11-11, `make test` 473개 통과, `make app` 성공):

- **확인**: 적힌 문제는 모두 코드에 있었습니다. 메뉴 승인 대기 줄은 `term != nil`이면 버튼을 보여 주고, 버튼이 없는 줄의 더블클릭은 `TerminalFocuser`로 바로 가서 `acknowledge`·로그를 건너뛰었습니다. 알림 클릭도 `acknowledge`를 하지 않았습니다.
- **알림 권한**: 허용되지 않은 상태로 기억하고 있으면 보내기 직전에 권한을 다시 읽고(그동안 쌓아 둠), 허용이면 보내고 아직 묻지 않았으면 묻고 거부면 버립니다. 앱이 활성화될 때도 다시 읽습니다. `.badge` 요청을 뺐고, `.passive`(조용히 바꾸는) 알림은 `willPresent`에서 배너 없이 목록만.
- **이동 한 곳으로**: OfficeCore `SessionDestination`(갈 곳·버튼 문구·도움말·번들 id 후보)과 `RosterRow.destination`·`canFocus`·`focusLabel`, 앱의 `SessionFocuser`(옛 `TerminalFocuser`·`DesktopAppFocuser`를 합침). 모르는 터미널이면 버튼·도움말·VoiceOver 동작이 없고, 메뉴 줄·알림 클릭도 `focusAgent`처럼 `acknowledge`와 로그를 거치며, 앱을 찾지 못하거나 열지 못하면 로그에 까닭을 남깁니다. 활성화는 `NSWorkspace.openApplication(at:configuration:)`(activates).
- **Cursor**: 훅 스크립트는 `X-Office-Term: $TERM_PROGRAM`과 `X-Office-Host-Session`만 보내고, Cursor도 `TERM_PROGRAM=vscode`라 구별할 수 없습니다. 지금 방식(실행 중인 VS Code → Insiders → Cursor 중 첫 앱)을 유지합니다. VS Code와 Cursor를 함께 띄워 두면 Cursor 세션이 VS Code를 올립니다. 구별하려면 훅 스크립트가 `__CFBundleIdentifier`(macOS가 앱에서 띄운 프로세스에 넣는 값)를 더 보내야 하는데, 스크립트를 바꾸면 모든 사용자가 다시 설치해야 해서 7번(훅 서버·설정 파일)과 함께 판단할 일로 남깁니다.
- **고장이 보이게**: OfficeServer `HookAlert.evaluate`(서버 멈춤 > settings.json 못 읽음 > 막힘 > 설치 안 됨 > 스크립트 낡음 > 이벤트 빠짐, 하나만)를 메뉴 배너·사무실 창 위쪽 30pt 띠(버튼 [훅 설치]/[다시 설치]/[연동 설정…] + "자세히…")·메뉴바 아이콘(오른쪽 위 빨강/주황 느낌표 원, VoiceOver "연동 문제: …")이 같이 씁니다. 설정 창 탭을 `settings.tab`에 기억해 띠에서 연동 탭으로 열 수 있습니다. 메뉴·띠·환영 창의 설치는 결과(성공 + "이미 실행 중인 Claude Code 세션은 다시 시작해야 적용돼요", 실패 + 까닭)를 닫을 때까지 보여 줍니다.
- **미니에는 넣지 않음**: 머리줄(20pt)이 상태와 다른 메인 칩으로 차 있고, 미니가 보일 때도 메뉴바 아이콘의 느낌표가 늘 보여서입니다.
- **남는 알림**: `Notifier`가 켤 때(init)와 끌 때(`shutdown`) 이 앱의 알림을 모두 지웁니다. 끌 때 지우기는 프로세스가 끝나기 전에 끝나지 않을 수 있어 켤 때 한 번 더 지웁니다.
- **첫 실행**: `MenuBarExtra` 드롭다운은 코드로 열 API가 없어 작은 환영 창(AppKit `NSWindow` + SwiftUI, 두 줄 소개, [훅 설치]·[사무실 보기]·[닫기])으로 했습니다. 훅이 설치돼 있지 않고 스크립트도 없을 때만 열고, 처음 켤 때 `onboarding.welcomeShown`을 기록하므로 이미 훅을 설치한 사용자에게는 뜨지 않습니다.
- **테스트**: `SessionDestinationTests`(데스크톱 우선, 아는 터미널, VS Code 후보 순서, tmux·zed·빈 값, 명단 줄), `HookAlertTests`(우선순위·버튼·색), `AccessibilityTextTests.menuBarProblem`.
- **화면 확인 필요**:
  1. 알림 권한: 시스템 설정에서 Claude Office 알림을 끈 채 앱을 켜고 승인 대기를 만든 뒤, 알림을 허용하고 다시 승인 대기를 만들면 알림이 떠야 합니다. 사무실 창을 앞에 둔 채 직함이 바뀌면(서브 번호 바뀜) 배너가 다시 뜨지 않아야 합니다.
  2. 남는 알림: 승인 대기 알림을 띄운 채 앱을 끄면(또는 다시 켜면) 알림 센터에서 사라져야 합니다.
  3. 이동: 메뉴 승인 대기 줄의 [터미널로]/[앱으로]가 미니만 보이는 상태(다른 앱이 앞)에서도 그 앱을 앞으로 가져오는지, 이벤트 로그에 "세션으로 이동 · …"이 남는지. tmux 안에서 연 세션은 버튼·도움말이 없어야 합니다.
  4. 띠·아이콘: 개발용으로 띄운 앱에서 `~/.claude` 를 건드리지 않고 확인하려면 `CLAUDE_OFFICE_ENDPOINT`를 다른 파일로 두고 서버 포트를 막거나(서버 실패) 설치 안 된 계정에서 봅니다. 띠의 버튼이 설치·설정 → 연동 탭으로 가는지, 메뉴바 아이콘 느낌표가 밝은·어두운 메뉴바에서 보이는지, VoiceOver가 "연동 문제"를 먼저 읽는지.
  5. 환영 창: 새 사용자 계정(또는 `defaults delete com.engyjoon.claudeoffice onboarding.welcomeShown` + 훅 없는 상태)에서 처음 켜면 한 번 뜨고, 다시 켜면 뜨지 않아야 합니다. 창이 다른 앱 뒤에 깔리지 않는지도 봅니다.

## 7. 훅 서버·설정 파일 안전

**문제 (코드, 일부 실험으로 확인)**

- **엔드포인트 파일 가로채기**: 설치된 앱이 켜진 채 `make serve`·`make run`을 돌리면 두 번째 프로세스가 엔드포인트 파일을 덮어쓰고 끝날 때 지웁니다. 설치된 앱은 "서버 실행 중"으로 초록인데 이벤트를 못 받습니다. (`App/Sources/AppModel.swift:223`, `:238`, `Sources/OfficeServer/HookInstaller.swift:30-32`, `Sources/office-sim/main.swift:253-268`)
- `EndpointFile.write`가 지운 뒤 옮겨서 원자적이지 않습니다. (`HookInstaller.swift:19-20`)
- 강제 종료·충돌 뒤 엔드포인트 파일이 남습니다. 훅 스크립트는 빈 PORT면 80번 포트로 보냅니다. (`Sources/OfficeServer/Resources/claude-office.sh:17-23`)
- **심볼릭 링크**: `settings.json`이 링크면 원자적 쓰기가 링크를 일반 파일로 바꿉니다(실험으로 확인). (`HookInstaller.swift:137-142`)
- 바뀐 것이 없어도 설치·제거 때마다 백업을 만들고 지우지 않습니다. (`HookInstaller.swift:95-99`, `:122-143`)
- 제거·재설치가 우리 명령이 든 그룹 전체를 지워, 같은 그룹에 넣어 둔 사용자 훅도 사라집니다. (`Sources/OfficeCore/Hooks/HookSettingsEditor.swift:113-128`)
- `bundledScript`가 매번 리소스를 읽고 없으면 `preconditionFailure`라, `make install`이 번들을 바꾸는 사이에 상태를 새로 읽으면 앱이 죽습니다. (`HookInstaller.swift:62-67`)
- **죽은 터미널 세션이 자리에 남음** (4번에서 넘어옴, 2026-11-11 사용자 결정: PID 확인 방식): SessionEnd를 못 받은 터미널 세션(kill -9, 터미널 창 닫기)은 앱을 다시 켤 때까지 사무실에 남습니다. 4번이 바쁜 상태는 풀어 주지만(1시간 뒤 쉬는 중) 퇴근은 시키지 않습니다. 훅만으로는 죽은 세션과 열어 둔 채 쉬는 세션을 가릴 수 없어서입니다. (`Sources/OfficeCore/Model/OfficeState.swift`의 `expireSilence`, 설계서 §5.2·§5.3)
- **서버**: 연결마다 전체 시간 제한이 없고(`recv`마다 2초), 동시 연결 수 제한이 없고, `accept`가 EMFILE로 실패하면 바쁜 대기, 토큰 검사는 본문을 다 받은 뒤입니다. 거절한 요청(413 등)은 어디에도 남지 않습니다. (`Sources/OfficeServer/HookServer.swift:164-204`, `Sources/OfficeServer/HTTP.swift:58`, `:100`, `:111`)

**고칠 방향**: 파일 내용이 자기 포트·토큰일 때만 지우고, `HookHealth`가 파일을 읽어 비교합니다. `rename(2)`로 바꿔 씁니다. 링크는 풀어서 대상에 씁니다. 바뀐 것이 없으면 쓰지 않고 백업은 최근 몇 개만 둡니다. 핸들러 단위로 지웁니다. `bundledScript`는 한 번만 읽습니다. 서버에 연결당 3초 제한·동시 연결 상한·`accept` 실패 뒤 짧은 쉼을 넣고, 머리줄을 다 받으면 토큰부터 검사하고, 거절 수를 설정 → 연동에 보여 줍니다. 본문 상한을 올린다면 `Expect: 100-continue`에 답해야 합니다(curl은 1MB 넘는 본문에 붙임).

죽은 터미널 세션 퇴근 (PID 확인):

- 훅 스크립트가 Claude Code 프로세스의 PID를 헤더로 함께 보냅니다(`X-Office-Pid`, 지금의 `X-Office-Term`·`X-Office-Host-Session`처럼). **먼저 확인할 전제**: 훅 스크립트의 `$PPID`가 Claude Code 자신인지 중간 셸(`sh -c`)인지. 셸이면 그 부모를 찾아야 합니다(`ps -o ppid= -p $PPID`). 훅마다 `ps`를 한 번 더 띄우는 비용도 잽니다.
- 서버가 숫자인지 검사해 넘기고, 앱이 세션마다 마지막으로 받은 PID를 기억합니다(코어 `OfficeState`는 PID를 모르게 둡니다. 순수 값 타입).
- 앱이 주기적으로(디렉토리 목록을 읽는 5초 주기면 충분) 데스크톱 id가 **없는** 세션의 PID가 살아 있는지 봅니다(`kill(pid, 0)`, `EPERM`은 살아 있는 것). 죽었으면 그 세션의 `sessionEnded` 이벤트를 엔진에 넣어 평소처럼 퇴근시킵니다(승진·행 닫기·알림 지우기는 리듀서가 이미 함). 데스크톱 세션은 지금처럼 데스크톱 목록이 맡습니다.
- PID 재사용: 죽은 뒤 같은 번호를 다른 프로세스가 받으면 살아 있는 것으로 보입니다. 프로세스 시작 시각이나 실행 파일 이름(claude)을 함께 확인합니다. 틀려도 퇴근이 늦어질 뿐입니다.
- PID를 못 받은 세션(옛 훅 스크립트, 앱을 켜기 전에 시작한 세션의 첫 훅 전)은 건드리지 않습니다. 설치된 훅 스크립트가 바뀌므로, 설치된 스크립트가 번들과 다르면 "다시 설치"를 권하는 1번의 진단에 걸리는지 확인합니다.
- 4번의 "SessionEnd 뒤 30초 안의 늦은 훅은 버림"이 이렇게 넣은 `sessionEnded`에도 적용됩니다. 살아 있는 세션을 잘못 퇴근시켰다면 30초 뒤의 훅이나 새 요청에 다시 출근합니다.

**완료 기준**: 항목마다 `OfficeServerTests`·`HookSettingsEditorTests`에 테스트가 있습니다. 죽은 세션 퇴근은 PID 헤더 검사와 "죽은 PID → 퇴근, 산 PID·PID 없음 → 그대로"를 테스트하고(살아 있는지 묻는 함수를 주입), 실제 `kill -9`는 "화면 확인 필요"로 남깁니다.

**결과** (2026-11-11, `make test` 488개 통과(473 + 15), `make app` 성공, 커밋 세 개 `개선 7(1)`·`7(2)`·`7(3)`):

- **확인**: 적힌 문제는 모두 코드에 있었습니다(엔드포인트 지운 뒤 옮김·끌 때 무조건 지움, 빈 PORT면 `http://127.0.0.1:/…`, 링크를 덮는 `.atomic` 쓰기, 매번 백업, 그룹째 제거, `preconditionFailure`, `recv`마다 2초·상한 없음·EMFILE 바쁜 대기·본문 뒤 토큰 검사, 거절 기록 없음).
- **(1) 파일 안전**: `EndpointFile.write`는 임시 파일 → `rename(2)`. `removeIfOwned`(앱 `shutdown`·`startServer`, `office-sim serve`)는 자기 포트·토큰일 때만 지웁니다. 앱은 5초마다 `EndpointFile.state`를 읽어 없어졌으면 다시 쓰고, 남의 것이면 `HookAlert.endpointLost`(빨강, 띠·아이콘·배너)와 연동 탭 "엔드포인트 파일" 항목·머리말로 알립니다(다투지 않음, "서버 다시 시작"으로 되찾음). `office-sim serve`는 파일이 이미 있으면 덮어쓴다고 경고합니다. 설치기: 링크를 풀어 대상에 쓰고 권한을 지킴, 백업은 링크가 아니라 내용(600), 결과 JSON이 같으면 쓰지도 백업하지도 않음(스크립트도 같으면 안 씀), `settings.json.bak-yyyyMMdd-HHmmss[-n]` 꼴만 최근 5개 남김. `HookSettingsEditor`는 우리 핸들러만 지우고 빈 그룹·빈 이벤트만 지웁니다(반환값은 지운 핸들러 수). `bundledScript`는 `static let`으로 한 번만 읽고, 없으면 설치가 `scriptResourceMissing` 오류를 내고 상태 판정은 비교를 건너뜁니다.
- **(2) 서버**: 연결 전체 3초(poll로 남은 시간만큼, 넘으면 408), 동시 32개(넘으면 503), `accept` 실패(EINTR·EAGAIN·ECONNABORTED 밖) 뒤 0.1초 쉼, 머리줄을 받으면 `evaluateHead`(Origin·경로·메서드·토큰·Content-Type)부터, 그다음 본문 크기(413). 토큰 없는 큰 요청은 이제 413이 아니라 401입니다. 거절 수는 `HookServer.rejectedCounts`(상태 코드별) → 연동 탭 "거절한 요청 3개 (401 토큰 틀림 2개, 413 본문 너무 큼 1개)". 본문 상한 1MB는 그대로입니다. 훅 스크립트는 PORT가 비었거나 숫자가 아니면 보내지 않습니다.
- **(3) 죽은 터미널 세션 퇴근 — 전제 확인**: 훅 문서 대신 실측했습니다. `CLAUDE_OFFICE_ENDPOINT`를 없는 파일로 두어 설치된 훅이 아무것도 보내지 않게 하고, 임시 설정(`--setting-sources project --settings …`, `--no-session-persistence`)으로 `claude -p`(2.1.321)를 돌려 SessionStart·UserPromptSubmit·Stop 훅에서 프로세스 트리를 적었습니다. 세 훅 모두 스크립트(`/bin/sh`)의 `$PPID`가 Claude Code(`claude`) 자신이었고(경로에 공백이 있어 따옴표로 감싼 명령도 같음), 중간 셸은 없었습니다. 그래도 다른 버전·설정을 위해 서버가 그 PID의 이름이 셸(`sh`·`bash`·`zsh`·`dash`·`ksh`·`tcsh`·`csh`·`fish`·`env`)이면 부모로 올라갑니다(4단계까지). 실행 파일 이름은 설치 방식마다 달라(`claude`, 버전 번호, npm의 `node`) 이름으로 고르지는 않습니다. 같은 실측에서 `__CFBundleIdentifier`가 훅 환경에 들어오는 것도 확인했습니다(데스크톱 앱 안이라 `com.anthropic.claudefordesktop`).
- **(3) 구현**: 스크립트는 `X-Office-Pid: $PPID`·`X-Office-App: ${__CFBundleIdentifier:-}`만 더 보냅니다(`ps`를 띄우지 않음). 서버(`HookRequestPolicy.hookParentPID`·`appBundleID`로 꼴 검사)가 202를 보내기 전에 `ProcessInspector.claudeProcess`(Darwin `sysctl KERN_PROC_PID`, Linux `/proc/<pid>/stat`)로 번호 + 시작 시각을 `HookDelivery.process`에 담습니다(데스크톱 세션은 보지 않음). 앱의 `SessionProcessTracker`가 세션마다 기억하고, 5초 주기(`refreshDirectories`)에 `sweep(isAlive:)`이 죽은 프로세스(시작 시각이 다르면 번호 재사용으로 봄)의 세션을 `sessionEnded(reason: "process_exited")`로 돌려줘 엔진에 넣습니다. 이벤트 로그에 "메인N: Claude Code 프로세스가 끝나 퇴근했어요". SessionEnd를 받으면 잊고, PID 없는 훅은 기억을 지우지 않고, `--resume`이면 새 PID로 바꿉니다. 4번의 30초 규칙이 그대로 적용됩니다(테스트로 확인).
- **(3) 비용**: 훅 스크립트 200번 × 2회를 로컬 서버(202 응답)에 보낸 평균이 옛 스크립트 10.56·9.56ms, 새 스크립트 9.87·9.69ms로 차이가 측정 오차 안입니다(대부분 curl 시작 시간). 서버 쪽 `sysctl` 조회는 한 번에 약 9µs입니다.
- **(3) 다시 설치 진단**: 설치된 `~/.claude/hooks/claude-office.sh`는 이전 번들(`9f3ebdb`)과 바이트까지 같고 새 번들과 다릅니다 → `scriptState` `.outdated` → `HookAlert.scriptNeedsFix` "훅 스크립트를 업데이트해야 해요"[다시 설치]가 뜹니다. 다시 설치 전까지는 옛 스크립트로 전처럼 동작하고 PID 퇴근·앱 구별만 빠집니다. 이미 실행 중인 세션도 스크립트 파일을 매번 새로 읽으므로 다시 설치하면 다음 훅부터 PID가 옵니다.
- **Cursor 구별**: `SessionDestination.resolve(hostSession:term:app:)` — 번들 id가 그 `TERM_PROGRAM`의 후보에 있으면 맨 앞에 두고 이름도 그 앱("Cursor"). 후보에 없는 값(tmux를 띄운 iTerm 등)은 쓰지 않아 버튼이 보이는지는 `term`만으로 정합니다. 앱의 `focusAgent`·알림 열기가 씁니다.
- **넣지 않은 것**: `PostToolBatch` 훅(페이로드 미수집, 아래 "새로 발견한 것" 그대로). 본문 상한 올리기.
- **간헐 실패 (개선 7(5))**: 코어를 채운 부하(`yes` 16개)에서 `swift test`가 15번 중 2~3번 실패했고, 7번 전 커밋도 같은 부하에서 15번 중 1번 실패하는 것을 보고 원인을 찾아 고쳤습니다. 원인 셋은 다음과 같습니다.
  - (1) `endToEndWithCurl`: 테스트 프로세스의 첫 curl이 부하에서 뜨는 데만 3초 가까이 걸려 `-m 3`에 걸렸습니다(`000`, 서버 거절 0). `-m`은 멈춤 막이(30)로만 둡니다.
  - (2) 7번 서버 테스트의 경과 시간 검사와 고정 sleep: 시간을 재는 대신 서버의 긴 제한·408 자체·연결 수(`activeConnectionCount`)를 조건으로 기다립니다. PID 끝에서 끝 테스트는 가짜 curl로 헤더를 보고, 서버의 PID 해석은 프로세스 안 요청으로 봅니다.
  - (3) **제품 경합**: 서버가 202를 보낸 뒤에 훅을 전달 줄에 넣어, 답을 받고 곧바로 온 다음 훅이 앞지를 수 있었습니다(부하에서 순서가 뒤집힌 것을 봄. 7번 전부터 있던 것). 줄에 넣은 뒤 답하게 고쳤고, 테스트용 훅(`afterAcceptResponse`)으로 첫 연결 스레드를 붙잡아 시간 없이 재현합니다. 옛 순서면 5번 모두 `[1, 0]`으로 실패합니다.
  - 고친 뒤 같은 부하에서 35번, 그리고 두 벌을 동시에 10번씩 돌려 모두 통과했습니다(490개).
- **테스트**: `OfficeServerTests`(엔드포인트 소유·rename, 링크 settings, 바뀐 것 없으면 안 씀·백업 5개, 머리줄 토큰 먼저·거절 수, 408, 503, 깨진 엔드포인트면 curl 안 부름), `SessionProcessTests` 5개(헤더 꼴, 죽은 PID → 퇴근·산 PID·PID 없음·데스크톱 → 그대로 + 30초 규칙, 기억 규칙, 프로세스 찾기·셸 건너뛰기·번호 재사용, 실제 스크립트 → 서버 PID·앱), `HookAlertTests.endpointLost`, `HookHealthTests.rejectedRequests`, `HookSettingsEditorTests.handlerLevelRemoval`, `SessionDestinationTests.launchingApp`. "실제 훅 스크립트 → 서버 → 엔진"·"앱이 꺼져 있어도 조용히 성공"은 그대로 통과합니다.
- **화면 확인 필요**:
  1. 다시 설치: 연동 띠·메뉴에 "훅 스크립트를 업데이트해야 해요"가 뜨고, [다시 설치] 뒤 settings.json 백업이 새로 생기지 않아야 합니다(훅 목록이 같으면). 백업 폴더(`~/.claude`)의 `settings.json.bak-*`이 5개 넘게 있었다면 오래된 것이 지워집니다.
  2. 죽은 세션: 다시 설치 뒤 터미널에서 `claude`를 띄워 요청 하나를 보내고 그 프로세스를 `kill -9`(또는 터미널 창을 닫음)하면 5초쯤 뒤 그 메인이 퇴근하고 이벤트 로그에 "프로세스가 끝나 퇴근"이 남아야 합니다. 열어 둔 채 쉬는 세션은 남아야 합니다.
  3. 가로채기: 앱이 켜진 채 `office-sim serve`를 기본 엔드포인트로 돌리면 5초 안에 빨간 띠 "훅이 이 앱을 찾지 못해…"가 뜨고, serve를 끄면 파일이 없어진 것을 보고 앱이 다시 써서 띠가 사라져야 합니다.
  4. Cursor: VS Code와 Cursor를 함께 띄운 채 Cursor 터미널의 세션을 더블클릭하면 Cursor가 앞으로 와야 합니다.

## 8. 화면 디자인 다듬기

**문제 (스냅샷 확인)**

- **상태 칩의 주인을 알기 어려움**: 칩은 28자(라틴 약 160pt, 한글 약 257pt)까지 넓어지는데 책상 간격은 92pt입니다. 혼잡한 행에서 서브4의 칩이 안마 의자 쪽으로 밀리고 서브5의 칩이 서브4 머리 위에 놓입니다(`make snapshot`의 `floor-030.00s.svg`). 미니에서는 긴 칩 셋이 겹칩니다. (`Sources/OfficeStage/Overlay.swift:105`, `:322`, `:339-341`)
- **밤 조명의 이모트**: ♪·Zz·전구 빛줄기·외침 선은 잉크색(0x3A3247)만 써서 밤 벽·바닥 위에서 대비가 1.3~1.6:1입니다(`office-sim snapshot Scenarios/delegation.jsonl --at 128 --night`). `OverlayArt.emote`가 조명을 받지 않습니다. (`Overlay.swift:493-497`, `:593-614`)
- **같은 디렉토리의 메인 구별**: 폴더 표지가 둘 다 "claude-office"입니다.
- **메뉴바 점**: 모두 끝나고 "답변 필요"만 남아도 초록 "작업 중"입니다. `.awaitingReply`의 톤이 `.calm`이 아니라서입니다. (`Sources/OfficeCore/Model/Roster.swift:155-160`)
- 보고 연출이 메인의 상태를 무시해, 자는 메인의 Zz나 승인 대기 "!"를 지웁니다. (`Sources/OfficeCore/Engine/Choreographer.swift:398-418`)
- NFD 한글(맥 파일 이름)은 칩 폭을 세 배쯤 넓게 잽니다. (`Overlay.swift:404-426`)
- 종이비행기는 회전을 좌표에 구워 매 장 새 텍스처를 만듭니다(요청마다 약 39장). (`Overlay.swift:237-248`, `:677-686`)
- 화면 확인 필요(SVG에서만 봄): 소파에 앉은 직원이 팔걸이 앞에 서 있는 것처럼 보입니다(`delegation-128.00s.svg`).

**고칠 방향**: 칩은 평소 책상 간격에 맞춰 자르고, 고르거나 마우스를 올린 사람만 전체를 보여 줍니다(옆으로 밀기보다 위로 쌓기). 이모트에 조명을 넘겨 밤에는 밝은 테두리를 줍니다. 같은 폴더의 메인이 둘 이상이면 표지에 세션 제목을 덧붙입니다(표시 수준이 상세일 때만). 답변 필요만 남으면 메뉴바 점을 사무실의 "?"와 같은 파랑으로 합니다. 보고 연출의 메인 쪽은 `!waiting && rest == .none`일 때만 합니다. 폭을 재기 전에 글자를 합칩니다(NFC). 종이비행기 각도는 15° 단위로 맞추거나 회전을 따로 둡니다.

**완료 기준**: 스냅샷(낮·밤·혼잡·미니)을 고치기 전후로 비교해 결과에 적고, `OverlayTests`가 통과합니다. 앱 화면은 "화면 확인 필요".

**결과**: 완료 (2026-11-11). 고치기 전 스냅샷(`make snapshot` 14장 + 밤 `delegation --at 2.6,20,52.2,128,400`·`floor --at 30`)으로 칩 문제와 밤 ♪를 직접 보고, 나머지는 코드로 확인한 뒤 고쳤습니다. 규칙은 설계서 §6.2(보고 연출 표), §6.7(종이비행기), §6.10(행 표지), §7.2(상태 칩·글자 폭), §8.2(밤 이모트), §10(메뉴바)에 적었습니다.

- **상태 칩의 주인** (`Overlay.items`, `pillRoom`, `fitPill`, `place(…, sideways:)`): 칩이 쓸 가로 자리를 "머리 높이가 비슷한(17+3pt 안) 옆 사람까지 거리의 절반 − 1.5"로 정해 그 폭에 맞춰 말줄임합니다. 칩 없는 사람도 셉니다(그 사람의 Zz·배지 자리를 덮지 않고, 옆 칩이 생기고 없어져도 폭이 흔들리지 않게). 서브 사이 92 → 칩 89pt, 메인과 첫 서브 사이 110 → 쪽마다 53.5라 더 넓고, 옆 사람이 없는 쪽은 화면 끝까지라 행 끝 서브·혼자인 메인은 예전처럼 다 보입니다. 한쪽이 좁으면 넓은 쪽으로 옮기되 머리는 늘 칩 아래. 칩끼리 겹치면 옆으로 밀지 않고 위로 쌓습니다(공용 구역 묶음 칩·말풍선은 예전 그대로 옆으로도 비킴). 최소 56pt. 마우스를 올리거나 고른 사람의 칩만 60자까지 전체를 보여 주고, 다른 칩을 밀지 않고 맨 나중(맨 위)에 덮습니다.
- **밤 이모트** (`OverlayArt.emote(_:lighting:)`, `bubble(…, lighting:)`, `strokeInk`): 밤에는 ♪·Zz·전구 빛줄기·외침 풍선의 터지는 선을 고른 직원 테와 같은 #FFF3D0으로 칠합니다(밤 벽 대비 약 1.4 → 8:1). 색을 채운 아이콘(전구 알·"!"·💦·✨·⏳)은 그대로. `Overlay.items`가 `options.lighting`을 넘기므로 SVG와 앱의 `OverlayNode`가 같은 `OverlayItem.shapes`를 그리고, `ShapeBaker` 캐시 키(도형)가 낮·밤을 구분합니다.
- **같은 폴더의 메인 구별** (`OfficeFloor.signTitles` → `Stage.signTitles` → `OfficeArt.layers(signTitles:)`·`sign(_:title:…)`): 보이는 행 가운데 같은 폴더(`Team.folder`)가 둘 이상이면 그 행들의 메인 세션 제목(`Part.title`, 데스크톱 앱이 알려 준 것)을 표지 둘째 줄에 9pt로 덧붙입니다(높이 20 → 30). 표시 수준이 상세일 때만(앱은 `store.privacy`, SVG는 `overlay.privacy`), 제목을 모르면(터미널 세션) 그대로. 제목 줄은 글자 폭 76("훅 서버·설정 파일…")이라 표지 오른쪽 끝이 x 129로 첫 서브 책상(139)에 닿지 않습니다. 폴더 이름 줄의 폭 규칙(136)은 그대로라 제목이 없는 표지는 바뀌지 않습니다. 앱은 `FurnitureKey.signTitles`가 바뀔 때 가구를 한 번 다시 굽습니다. 제목은 지시가 올 때(`OfficeFloor.apply`)마다 다시 정하므로, 제목 힌트만 늦게 오면 그 세션의 다음 훅에 표지가 바뀝니다.
- **메뉴바 점** (`Roster.Mood.reply`, `MenuBarIcon`): 승인 대기 > 작업 중 > 답변 필요 > 쉬는 중. 일하는 사람 없이 "답변 필요"가 남으면 `.reply`로, 점을 사무실 "?" 배지와 같은 파랑(#5B8DEF, `OverlayArt.replyBlue`)으로, 건물은 빈 건물(쉬는 중과 같음), 기본 VoiceOver 문구는 "Claude Office · 답변 필요"(사람 수 문구는 원래 "답변 필요 N명"). 상태 점은 오른쪽 아래, 고장 느낌표(개선 6)는 오른쪽 위라 겹치지 않습니다.
- **보고 연출** (`Choreographer` `.reported`): 메인이 승인 대기(`presence.waiting`)·쉬는 중(`rest > .none`: 소파·안마 의자·잠)·정리 중(`compacting`)이면 메인 쪽 연출(`await`~`awaitEnd`, 하이파이브·"고마워요"·✨·표정 되돌리기)을 하지 않습니다. 이때 서브도 메인에게 걸어가지 않고 신호를 보내지 않아(짝이 되는 `await`가 없으므로 개선 5의 `withdraw`와도 어긋나지 않음) 제자리에서 뿌듯해하고 보고 효과음 뒤 퇴근합니다. 메인이 평소 상태면 예전과 같습니다(`make demo`의 위임 시나리오 그대로).
- **칩 폭 재기** (`TextMetrics.width`): NFC로 합친 뒤 grapheme마다 첫 글자 폭만 셉니다. 풀어 쓴 한글·합친 한글이 같은 폭, 👨‍👩‍👧·❤️·👍🏽·🇰🇷가 한 글자. 홀로 남은 폭 없는 글자(ZWJ·변형 선택자 등)는 0.
- **종이비행기** (`OverlayArt.snappedPlaneAngle`): 기울기를 15° 단위로 맞춰 한 번 나는 동안 그림이 7가지(테스트: 30fps 약 39프레임에 ≤ 8가지)이고, 다음 비행도 같은 각도들이라 앱의 `ShapeBaker` 캐시가 다시 씁니다. 회전을 노드로 따로 두는 쪽은 `OverlayNode`(App)와 `OverlayItem`에 각도를 더해야 해서 고르지 않았습니다.
- **소파 (화면 확인 필요)**: 좌표는 어긋나지 않았습니다. 바깥 자리(x = 소파 + 28)는 팔걸이 안쪽 끝에서 12pt 안이고, 몸(±15)이 팔걸이 뒤로 3pt 들어가 가려지며(팔걸이 층 깊이 215.5 > 직원 214), 앉은 다리(깊이 +2)는 좌판 앞에 그려지고 발끝은 바닥(y 227, 소파 밑단 226~228)입니다. 팔걸이 바로 옆에서 종아리가 바닥까지 내려와 "팔걸이 앞에 선" 느낌이 나는 것은 다리 길이·자리 간격의 디자인 문제라, 앱 화면에서 보고 정합니다(바깥 자리를 4pt 안으로 당기면 몸은 팔걸이에서 떨어지지만 자리 간격이 36으로 줄어 팔끼리 2pt 겹침).
- **테스트** (10개 추가): `DesignPolishTests`(혼잡한 행의 칩이 주인 머리 위·한 줄·겹치지 않음·옆 사람 머리 위로 안 넘어감·메인 쪽이 더 넓음 / 마우스 올림·고름만 전체이고 다른 칩은 그대로 / 미니 띠의 긴 칩 셋 / NFD·이모지 폭 / 밤 이모트 색과 SVG / 종이비행기 각도 / 같은 폴더 표지 제목·상세만·폭 제한), `RosterTests`("답변 필요만 남으면 reply"), `ChoreographerTests`(승인 대기·잠자는 메인에게 보고). `make test` 500개 통과(490 + 10), `make app` 빌드 성공.
- **스냅샷 비교** (고치기 전 → 뒤, 같은 명령):
  - **그대로 (바이트까지 같음)**: 위임 11·20·52.2·61.5·128초, 미니 8·12·45초, 밤 위임 52.2·400초. 칩이 혼자이거나(위임) 짧은 장면, 잉크 이모트가 없는 밤 장면.
  - **혼잡 `floor-030/052/080`**: 예전에는 칩 15개가 모두 "Bash · swift build"(약 99pt)라 서브4의 칩이 안마 의자 쪽으로 밀려 올라가고 서브5의 칩이 서브4 머리 위에 놓였는데, 이제 모두 제 머리 위 한 줄입니다. 서브 사이는 "Bash · swift…", 메인 옆 첫 서브는 "Bash · swift bu…", 행 끝 서브와 메인은 "Bash · swift build". 행 표지는 메인1 "claude-office / 화면 디자인 다듬기", 메인2 "claude-office / 훅 서버·설정 파일…"이 됐습니다(시나리오 `Scenarios/floor.jsonl`에 메인1·메인2 세션 제목 힌트를 넣음, 예전 코드에서는 제목을 쓰지 않으므로 그림 비교에 영향 없음). 칩·표지 밖(직원·가구·아이콘)은 같습니다.
  - **미니 `020`·`065`**: 예전 065초는 메인 칩이 위로 쌓여 띠 위 끝에 붙고 "WebSearch · NSPanel floating" 칩이 메인 쪽으로 밀렸는데, 이제 셋이 한 줄("Read · README.md", "WebSearch · N…", "Bash · swift test")로 각자 머리 위입니다. 020초는 "Bash · rm -rf build" → "Bash · rm -rf b…".
  - **밤 `128`**: 소파 위 ♪가 밤 벽과 같은 잉크색이라 거의 안 보이던 것이 밝은 크림색으로 보입니다. **밤 `020`**: 외침 풍선의 터지는 선이 밝아짐. **밤 혼잡 `030`**: 메인들의 전구 빛줄기가 밝아짐 + 위 칩·표지 변화.
  - **위임 `002.6`(낮·밤)**: 종이비행기 기울기 −56.6° → −60°(15° 단위). 그 밖은 같습니다.
- **화면 확인 필요**: (1) 사무실 창에서 마우스를 올리거나 고른 직원의 칩이 전체로 펼쳐져 옆 칩 위에 덮이는지, 내리면 다시 줄어드는지. (2) 답변 필요만 남았을 때 메뉴바 점이 파랑이고 빈 건물인지, 고장 느낌표와 함께 보일 때 겹치지 않는지. (3) 같은 폴더 세션 둘을 데스크톱 앱에서 열었을 때 표지 둘째 줄(상세에서만). (4) 밤에 ♪·Zz·전구 빛줄기가 소파 스탠드 불빛 위에서도 읽히는지. (5) 소파 바깥 자리 모습(위). 설치된 앱은 바꾸지 않았습니다.

## 9. 문구·경과 시간·잔손질

**문제 (코드)**

- **낡은 문구**: "창을 넓히면 더 보여요"(창은 M5(9)부터 고정 크기, `App/Sources/StaffPanel.swift:42`), "세션은 사이드바에서 골라 주세요"(M5(7b)부터 세션까지 열림, `App/Sources/MenuContentView.swift:189`). 빈 상태 안내가 메뉴는 "터미널에서 claude를 실행하면", 패널은 "Claude 데스크톱 앱에서 세션을 시작하면"입니다. 같은 동작이 "사무실 보기"와 "사무실 창 열기"로 불립니다.
- **경과 시간이 다섯 벌**: 메뉴는 분이 넘어가지 않아 "쉬는 중 4320분"(`MenuContentView.swift:219-223`), 미니는 "72시간 전"(`App/Sources/MiniOfficePanel.swift:755-761`), 인스펙터는 초 없는 사본(`App/Sources/AgentCard.swift:295-300`), 코어에 `StatusLine.elapsed`·`AgentTimeline.ago`.
- `case 36, 76 where modifiers.isEmpty`의 `where`가 76에만 걸려 ⌘·⇧+Return도 세션 이동입니다. (`App/Sources/ClaudeOfficeApp.swift:306`)
- 테스트 이벤트 수가 `receivedHooks - before`라 그 사이 온 실제 훅까지 셉니다. (`App/Sources/AppModel.swift:904-907`)
- `make install`이 실행 중인 앱을 끄지 않고 번들을 바꾸고, `xcodebuild … | tail -n 20`이 빌드 오류를 자릅니다. `make uninstall`은 훅을 남깁니다. (`Makefile:76-90`)
- 이벤트 로그가 새 줄마다 맨 아래로 스크롤해 지난 줄을 읽을 수 없습니다. 닫은 설정 창의 1초 타이머와 닫은 로그 창이 계속 갱신될 수 있습니다(전제 미확인). (`App/Sources/EventLogView.swift:16-48`, `App/Sources/SettingsView.swift:200-201`)
- 미니 위치: 저장한 자리가 `visibleFrame` 밖으로 조금만 나가도 오른쪽 아래로 초기화하고, `keepOnScreen`이 패널이 놓인 화면이 아닌 `NSScreen.main`을 씁니다. (`MiniOfficePanel.swift:408-435`)
- 낡은 주석: `Sources/OfficeCore/Model/OfficeState.swift:61`(curl 백그라운드), `Sources/OfficeCore/Model/OfficeEvent.swift:34`(팀장).

**고칠 방향**: 문구를 지금 동작에 맞추고 용어를 하나로 합니다. 경과 시간은 코어의 함수 하나(분 → 시간 → 일)로 모읍니다. Return은 `case 36 where …, 76 where …`로 나눕니다. 테스트 이벤트는 테스트 세션 id로 셉니다. `make install`은 실행 중이면 끄라고 안내하고 멈추거나 끄고 다시 엽니다(`-quiet`로 오류는 보이게). 로그는 맨 아래를 보고 있을 때만 따라갑니다. 미니 자리는 초기화하지 않고 화면 안으로 당깁니다.

**완료 기준**: 경과 시간 함수 테스트, `make test`·`make app` 통과.

**결과** (2026-11-11):

- **문구**: StaffPanel의 "창을 넓히면 더 보여요"는 지움. "세션은 사이드바에서 골라 주세요"는 6번에서 이미 없어져 있어 손대지 않음. 빈 상태 안내는 메뉴·패널 모두 "Claude 데스크톱 앱이나 터미널에서 세션을 시작하면 메인이 출근해요". 같은 동작은 "사무실 창 열기"로 통일(메뉴·환영 창·README·설계서·M2-build). 7번이 넘긴 것: 인스펙터·메뉴 버튼 도움말과 마우스 올림 도움말이 `model.destination(for:)`로 띄운 앱(Cursor 등) 이름을 씀. 화면 문구를 훑어 남은 "팀장·팀원"(소리 설정 설명, 주석)도 메인·서브로.
- **경과 시간**: `Sources/OfficeCore/Model/ElapsedText.swift` 한 벌 (`duration`·`ago`·`nextChange`). `StatusLine.elapsed`·`AgentTimeline.ago`·`AgentCard.elapsed`·미니의 `ago`·메뉴의 분 단위를 모두 없애고 이것을 부름. 초 → 분 → 시간 → 일 (메뉴 "쉬는 중 4320분" → "쉬는 중 3일 0시간째", 미니 "72시간 전" → "3일 전"). 메뉴·패널·미니처럼 30초·1분마다 갱신하는 곳은 `showSeconds: false`. 갱신 일정은 `StatusLine.nextChange`·미니 `nextChange` 모두 `ElapsedText.nextChange`를 써서 M6(1)의 "글자가 바뀌는 때만 다시 그림"·`liveClock`은 그대로. 지난 시간이 1시간을 넘으면 갱신이 1시간 단위로 늘고 지속은 하루부터(글자가 시간 단위로만 바뀜). 테스트: 59초·60초·59분·60분·23시간·24시간·3일 경계, 그리고 4일 동안 글자가 바뀌는 순간과 `nextChange`가 어긋나지 않는지 훑는 테스트.
- **Return 키**: `case 36 where modifiers.isEmpty, 76 where modifiers.isEmpty`.
- **테스트 이벤트 수**: 지금 보내는 테스트 세션 id의 훅만 세는 `testHooksArrived`.
- **Makefile**: `make install`·`make uninstall`은 `Claude Office`가 실행 중이면 "메뉴바 아이콘 → 종료한 뒤 다시 실행하세요"라고 알리고 멈춤(자동으로 끄지 않음). `xcodebuild -quiet … build`(`| tail` 제거)라 오류가 잘리지 않고 성공 때 출력도 짧음. `make uninstall`은 훅이 남는다는 안내를 출력. 실행 확인은 `make -n install`로만 했고 `docs/INSTALL.md`에 한두 줄 보탬(README·CLAUDE.md의 설치 설명은 그대로 맞음).
- **이벤트 로그**: 방금까지의 마지막 줄이 화면에 있을 때만 새 줄로 따라감. 화면 확인 필요 (List의 onAppear/onDisappear로 보이는 줄을 추적, 위로 올려 읽는 중에 줄이 들어와도 그대로인지).
- **미니 위치**: `initialFrame`은 저장한 자리를 `clamped`로 화면 안으로 당기고(기억한 자리가 없을 때만 오른쪽 아래), `keepOnScreen`은 패널이 놓인 화면(`panel.screen`)을 쓰고 그 화면이 없을 때만 메인 화면. 화면 확인 필요 (Dock 크기를 바꿔 왼쪽 아래 미니가 제자리에 있는지).
- **주석**: OfficeState의 curl 설명(스크립트는 앞에서 보내고 훅마다 따로 떠서 순서가 바뀔 수 있음)과 OfficeEvent의 "팀장"을 고침.
- **닫은 창 갱신(전제 미확인)**: 설정 창의 1초 시계는 `controlActiveState`가 비활성이면 갱신을 건너뛰고, 다시 활성화되면 바로 갱신(`liveClock`과 같은 생각이지만 "키 창인가"로 판정해, 보이지만 뒤에 있는 설정 창은 멈춤). 이벤트 로그 창은 닫혀도 모델의 `log`를 보는 뷰가 남는지 확인하지 못함 — **화면 확인 필요**(닫은 뒤 CPU, `make perf`).

## 10. 레티나 메모리 줄이기

**문제 (실측)**: 5K 2배율 화면에서 실행 3시간 41분 뒤 `footprint`가 326MB입니다(목표는 1배율 150MB). 그래픽이 약 240MB입니다(unmapped graphics 146MB, IOAccelerator 77MB, IOSurface 20MB). 설계서 §8.3이 "레티나면 넘을 가능성이 큼"이라며 측정을 미뤄 둔 부분입니다.

- 캐릭터·말풍선은 텍스처 배율이 바뀌어도 다시 굽지 않습니다. 1배율 화면에서 켠 뒤 레티나가 붙으면 흐리고, 반대면 4배 텍스처를 계속 듭니다. (`App/Sources/ShapeBaker.swift:27-33`, `App/Sources/OfficeScene.swift:350-354`, `:704-752`) — 11번에서 `OfficeScene.swift`를 나눠 캐릭터 노드는 `App/Sources/CharacterNode.swift`, 도형 → 노드(`ArtNodes`·`OverlayNode`)는 `App/Sources/ArtNodes.swift`에 있습니다. 줄 번호 대신 심볼로 찾습니다.
- 텍스처 캐시는 300장에서 통째로 비웁니다. (`ShapeBaker.swift:49`, `:156`)
- `AVAudioEngine`을 소리 묶음마다 메인 스레드에서 시작합니다(전제 미확인: 끊김). (`App/Sources/SoundPlayer.swift:85-118`)

**고칠 방향**: 먼저 `make perf`와 `footprint`로 상황별(메뉴바만·미니·사무실 창) 메모리를 재서 어디가 큰지 나눕니다. 그다음 바닥·벽 같은 큰 층을 1배율로 굽기, 그림판 크기, 배율이 바뀔 때 캐릭터 다시 굽기, 캐시를 오래된 것부터 비우기를 차례로 재며 적용합니다. 목표를 "1배율 150MB / 2배율 ○○MB"로 나눠 설계서에 적습니다.

**주의**: 측정에는 앱 실행이 필요합니다. 설치된 앱을 바꾸지 않고 `scripts/perf-launch.sh isolated`의 격리 실행을 쓰되, 실행 중인 앱과 충돌하면(엔드포인트 파일, 7번 항목) 멈추고 사용자에게 묻습니다.

**완료 기준**: 고치기 전후 측정값이 `build/perf/results.md`와 이 문서에 있습니다.

**결과 — 1단계** (2026-11-11, 앱을 한 번도 실행하지 않음. 아래 "설명되지 않는 몫"은 2단계에서 화면 밖 SKView 굽기로 밝혀짐. 커밋 `a66bbca`·`245ddfe`·`75fa720`·`944d989`): `make test` 516 → 524개 통과, `make app` 통과, `make snapshot` SVG 14장은 시작 전 사본과 바이트까지 같음.

- **먼저 짚어 둘 것**: 실측한 환경(5K 2배율 화면 하나)에서는 아래 (2)의 "배율이 바뀔 때 다시 굽기"가 메모리를 줄이지 않습니다. 원래도 그 화면에서는 모든 것을 2배로 구웠습니다. 이번 수정 가운데 그 326MB에 닿는 것은 (3)의 캐시 상한(최대 32MiB)뿐이고, 계산으로는 그래픽 240MB 가운데 상당 부분을 텍스처로 설명할 수 없습니다(아래 (1)). 2단계 측정이 필요합니다.

- **(1) 현황과 텍스처 크기 계산표 (실측 아님, 계산)**
  - **무엇을 어떻게 굽는가**: 글자가 아닌 도형은 `ShapeBaker`가 CoreGraphics 비트맵(RGBA 8비트, 배율을 곱한 픽셀)으로 굽고 스프라이트로 그립니다. 글자는 `SKLabelNode`(SpriteKit이 뷰의 배율로 그림). 도형 묶음은 글자에서 끊어 한 장씩 굽습니다(`ArtNodes.node`). 텍스처 크기 = 도형 경계 상자 + 테두리 1pt를 정수 포인트로 맞추고(`integral`) 보이는 영역으로 자른 것 × 배율.
    - **바탕·벽·행 표지**(깊이 −∞ 묶음): 사무실 창 크기만 한 한 장. 배율을 곱한 픽셀이 100만을 넘으면 화면 밖 `SKView.texture(from:)`로 GPU에서 굽고 **캐시하지 않습니다**(2배율 사무실 창). 1배율 사무실 창(약 88만 픽셀)은 CPU로 굽고 캐시에 들어갑니다.
    - **가구**: 깊이가 같은 층(한 행의 책상들·의자들 등)을 한 장으로. 창 크기·행·명패·행 표지 제목·조명·대비가 바뀌면 다시 굽습니다(0.25초마다 확인). 30초 넘게 안 보이는 장면은 놓습니다.
    - **움직이는 가구**(안마 롤러·모니터 진행 막대): 1/15초 단위로 맞춰 주기마다 같은 텍스처를 캐시에서 다시 씀(롤러 하나 한 주기 39장).
    - **밤 책상 불빛**: 사람 있는 책상마다 166×126pt 한 장.
    - **캐릭터**: 부위(머리카락 뒤·다리 둘·팔 둘·그림자·몸통·얼굴·눈·얼굴 세부·손 소품·든 소품·손 제스처·앉은 다리)마다 한 장, 같은 모습·색이면 사람끼리 공유. 노드를 만들 때 굽고, 표정·소품·제스처·조명이 바뀐 부위만 다시 굽습니다.
    - **말풍선·칩·아이콘·배지**: 도형이 바뀔 때만 다시 굽습니다.
    - **캐시**: 키 = 도형·색·자른 영역(이번에 배율 추가). 예전에는 300장에서 통째로 비웠고, 바이트 상한이 없었습니다. 캐시에서 버려도 화면의 노드가 든 텍스처는 살아 있습니다.
    - **그림판**: SKView마다 `CAMetalLayer` 그림판 2장(`limitDrawables`), 크기 = 뷰 × 배율.
  - **크기 정리**: 사무실 창은 크기가 고정(M5(9))이라 "최대 크기" = 기본 크기입니다(사무실 SKView 1180×748pt). 화면이 작으면 줄기만 합니다. 미니 SKView는 390×180pt.
  - **계산 방법**: 임시로 `office-sim snapshot`에 계산 코드를 붙여(커밋하지 않음) 시나리오의 그 순간 무대에서 앱과 같은 규칙(`OfficeArt.layers` → 깊이별 묶음 → 글자에서 끊기 → CGPath 경계 상자 → `integral` → 보이는 영역으로 자름, 같은 키는 한 번)으로 포인트²를 셌습니다. 바이트 = 포인트² × 배율² × 4. 글자는 `TextMetrics.width × 글자 크기 1.3`으로 어림했습니다. 계산 코드와 원래 출력은 공유 노트 폴더의 `improve-10-texture-calc*`에 있습니다.

  | 층 (화면에 그 순간 들고 있는 것) | 사무실 창 낮, 18명 (`floor` 30초) | 사무실 창 밤, 18명 | 사무실 창 낮, 2명 (`delegation` 52.2초) | 미니 낮, 3명 (`mini` 20초) | 미니 밤 |
  |---|---|---|---|---|---|
  | 바탕·벽·행 표지 | 3.42 / **13.67** MB (1182×751pt 한 장 + 표지 조각) | 3.42 / 13.67 | 3.39 / 13.54 | 0.28 / 1.14 | 0.28 / 1.14 |
  | 가구 (깊이별 묶음) | 0.79 / 3.16 (25장, 가장 큰 976×108pt) | 0.80 / 3.22 | 0.27 / 1.08 | 0.10 / 0.41 | 0.10 / 0.41 |
  | 움직이는 가구 (한 장면분) | 0.03 / 0.14 (17장) | 0.03 / 0.14 | 0.02 / 0.07 | 0 | 0 |
  | 밤 책상 불빛 | — | 1.44 / **5.74** (18장) | — | — | 0.24 / 0.96 |
  | 캐릭터 부품 | 0.70 / 2.82 (162장) | 0.73 / 2.92 | 0.07 / 0.30 | 0.12 / 0.48 | 0.12 / 0.50 |
  | 말풍선·칩·아이콘 | 0.03 / 0.11 | 0.03 / 0.12 | 0.03 / 0.14 | 0.02 / 0.09 | 0.03 / 0.10 |
  | 글자 `SKLabelNode` (어림) | 0.09 / 0.36 (39개) | 0.09 / 0.36 | 0.01 / 0.06 | 0.02 / 0.07 | 0.02 / 0.07 |
  | 그림판 2장 | 6.73 / **26.94** | 6.73 / 26.94 | 6.73 / 26.94 | 0.54 / 2.14 | 0.54 / 2.14 |
  | **합** | **11.8 / 47.2** | **13.3 / 53.1** | **10.5 / 42.1** | **1.1 / 4.3** | **1.3 / 5.3** |

  (각 칸은 1배율 / 2배율 MB, MiB 기준.) 이 밖에 계산할 수 있는 것: 조명 크로스페이드 0.6초 동안 사무실 장면 한 장(1배율 3.4MB / 2배율 13.5MB), 사무실 창 전체(사무실 + 현황 줄 + 패널 + 제목 막대, 약 1441×866pt)의 창 서버 백버퍼 한 장(1배율 약 5MB / 2배율 약 19MB — 실측 IOSurface 20MB와 크기가 맞지만 같은 것인지는 미확인).
  - **실측 240MB 나누기 (2배율, 사무실 창 + 미니)**: 계산으로 설명되는 몫은 화면이 그 순간 들고 있는 텍스처·그림판 약 **50~60MB** + 창 백버퍼 약 19MB + 캐시에 남은 몫(예전 규칙에서 2배율 가구 한 벌이 약 3MB, 명패·행 표지 제목·조명이 바뀔 때마다 한 벌씩 300장까지 쌓였다가 통째로 비워짐: 수 MB ~ 수십 MB 톱니) 정도입니다. **설명되지 않는 몫이 약 150MB 이상**이고 후보는 다음과 같습니다(모두 미확인):
    1. **바탕을 GPU로 구울 때마다 생기는 렌더 타깃**: 2배율 바탕(약 14MB)은 가구를 다시 만들 때마다(명패·행 표지 제목·조명·대비가 바뀔 때) 화면 밖 SKView로 새로 굽습니다. 옛 텍스처를 놓아도 SpriteKit·Metal이 렌더 타깃을 풀에 남기면 3시간 넘게 쌓일 수 있습니다. 조명 크로스페이드의 `view.texture(from:)`도 같은 꼴(13.5MB).
    2. **CPU 사본**: `SKTexture(cgImage:)`가 GPU에 올린 뒤에도 CGImage(같은 크기)를 들고 있으면 캐시·화면의 작은 텍스처가 두 배.
    3. **낮·밤 두 벌**: 조명이 바뀌면 다른 벌의 가구·불빛이 캐시에 남음(예전 규칙에서는 300장이 찰 때까지).
    4. **Metal·SpriteKit 바탕 몫**: 1배율에서도 측정한 GPU 몫(약 80MB, 설계서 §8.3)이 1배율 계산값(약 13MB)보다 훨씬 커서, 배율과 상관없는 몫(셰이더·명령 버퍼·드라이버 풀, SKView 두 개)이 큰 것으로 보입니다.
    5. 그 밖의 창(메뉴바 메뉴·설정 창)의 백버퍼, `SKLabelNode` 글자 텍스처.
  - **2단계에서 이 계산이 맞는지 가리는 법**: (a) 메뉴바만 → 미니만 → 사무실 창을 차례로 열며 `footprint`의 그래픽 몫이 미니 약 +5MB, 사무실 창 약 +47~53MB(+창 백버퍼 19MB)만큼 느는지. (b) 앱 안 계측(`perf.log`)의 `textures`(캐시 장 수·MB)와 `large`(GPU로 구운 바탕 "폭x높이@배율x")가 계산과 맞는지. (c) 낮·밤을 여러 번 바꾸고 세션이 드나들게 해 가구를 계속 다시 굽게 한 뒤 그래픽 몫이 계속 느는지(후보 1·2·3), 새 빌드는 캐시가 32MiB에서 멈추는지. (d) `CLAUDE_OFFICE_BAKE_SCALE=background=1`로 띄워 사무실 창 몫이 약 10MB(13.67 → 3.42) 줄어드는지. (e) `vmmap --summary`로 IOAccelerator·IOSurface·CG image 영역을 나눠 보기.

- **(2) 배율이 바뀔 때 다시 굽기 — 전제는 절반만 맞았습니다**: 예전 굽는 배율은 창의 배율이 아니라 **연결된 화면 중 가장 높은 배율** 하나(`ShapeBaker.scale`)였습니다. 그래서 (a) 창을 1배율 ↔ 레티나 화면으로 옮겨도 배율이 바뀌지 않았고, 1배율 화면과 레티나 화면을 함께 쓰면 1배율 화면의 창도 2배로 구워 텍스처가 4배였습니다. (b) 화면을 붙이거나 떼서 그 최댓값이 바뀌면 캐시를 비우고 가구는 다시 구웠지만(`generation`), **캐릭터 부위와 말풍선은 다시 굽지 않았습니다**: 몸통·얼굴·팔다리·머리카락은 그 직원이 사무실에 있는 동안 처음 배율 그대로라, 1배율에서 켠 뒤 레티나를 붙이면 계속 흐리고 반대면 4배 텍스처를 계속 들었습니다.
  - **고친 것**: 장면(사무실 창·미니 각각)이 매 장 자기 창의 `backingScaleFactor`를 보고(숫자 하나 비교), 바뀌면 가구·움직이는 가구·책상 불빛을 다시 굽고, 캐릭터 노드를 같은 장에서 새 배율로 다시 만들고(나타나는 효과·VoiceOver 알림 없이, 고른 직원 외곽선 유지), 말풍선·칩은 `OverlayNode`가 배율이 바뀐 것을 보고 다시 굽습니다. 그리고 `ShapeBaker.use(scales:by:)`로 어느 장면도 쓰지 않게 된 배율의 텍스처를 캐시에서 버립니다. 창에 붙기 전에는 예전처럼 연결된 화면 중 가장 높은 배율을 씁니다. 멈춘(안 보이는) 장면은 다시 보이는 첫 장에서 굽습니다. 화면 구성 알림(`screensChanged`)은 이제 "창에 붙기 전 배율"만 다시 정합니다.
  - 캐시 키에 배율이 **없었습니다**(전역 배율이 바뀌면 통째로 비워서 괜찮았음). 장면마다 배율이 다를 수 있어 키에 넣었습니다.
  - 테스트: 장면 쪽은 SpriteKit이라 단위 테스트가 없고, 규칙(배율별로 버리기, 층별 배율)은 `TextureBudgetTests`에 있습니다.

- **(3) 캐시를 오래된 것부터 비우기**: `OfficeStage`의 순수 타입 `TextureCacheLedger`(키·픽셀 수·배율·마지막으로 쓴 때만 셈, 텍스처는 앱의 `ShapeBaker`가 들고 장부가 버리라는 키를 지움). 장 수 또는 픽셀 합이 넘으면 가장 오래 안 쓴 것부터 들어갈 때까지 버리고, 혼자 상한을 넘는 것은 담지 않습니다. 테스트 8개(`TextureBudgetTests`).
  - **바이트(픽셀) 상한을 넣었습니다**: 장 수만으로는 큰 가구 묶음(2배율 976×116pt 한 장 1.7MB)이 300장 차면 이론상 500MB까지 갈 수 있었습니다. 상한 **8Mi 픽셀 = RGBA 32MiB**: 계산한 작업 묶음(2배율 사무실 창 낮 약 1.6M + 밤 약 3.2M 픽셀 + 미니 낮·밤 약 0.8M, 합 약 5.6M)이 여유 있게 들어가는 크기입니다. 1배율에서는 4배 여유.
  - **장 수 300 → 400**: 18명 사무실 한 조명이 약 230장이고 안마 롤러 한 주기가 39장이라 300이면 꽉 차서, 예전에는 차는 순간 통째로 비워 롤러·캐릭터 부위를 다시 구웠습니다. 이제는 가장 오래 안 쓴 것(대개 이미 화면에 있는 부위)만 빠집니다.
  - 장부의 "가장 오래된 것 찾기"는 담을 때만 장부 전체를 훑습니다(400장, 비트맵 굽기에 비하면 무시할 만함).

- **(4) 층별 굽는 배율 자리 (켜지 않음)**: `BakeScalePolicy`(층: 바탕·가구·캐릭터·말풍선)를 `ShapeBaker.policy` 한 곳에 두고 장면이 층마다 `bakeScale(_:)`로 묻습니다. **기본은 모든 층이 화면 배율**(지금 동작). 2단계에서는 다시 빌드하지 않고 환경 변수로 견줄 수 있습니다: `CLAUDE_OFFICE_BAKE_SCALE=background=1`(바탕만 1배율), `background=1,furniture=1` 등(0.5~4, 모르는 값은 무시). 1배율로 구운 층은 스프라이트 크기가 포인트라 화면에서 늘려 그려집니다(흐림). 설정 기본값(UserDefaults)이 아니라 환경 변수로 둔 것은 설치된 앱과 설정 도메인을 같이 쓰기 때문입니다.
  - **그림판 크기 줄이기는 자리를 만들지 않고 방법만 적습니다**: 계산상 가장 큰 몫(2배율 사무실 창 26.9MB)이지만 SKView는 그림판 크기를 뷰 × 창 배율로 스스로 정합니다. 줄이려면 `OfficeSKView`에서 `CAMetalLayer.contentsScale`·`drawableSize`를 1배율로 고정하고 `viewDidChangeBackingProperties`에서 다시 맞추는 방법(글자까지 모두 흐려짐), 또는 그림판 2장 → 1장은 30fps에서 기다림이 생길 수 있어 실측 화질·끊김 비교가 필요합니다.

- **(5) `SoundPlayer` — 판단만, 고치지 않음**: `AVAudioEngine`은 앱에 **하나**(모델이 한 번 만듦)이고 소리 묶음마다 새로 만들지 않습니다. 다만 마지막 소리 2초 뒤 엔진을 멈추므로, 조용하다가 처음 울리는 소리마다 **메인 스레드에서 `prepare()`·`start()`를 동기로 부릅니다**. 그래서 전제의 "묶음마다 메인 스레드에서 시작"은 맞습니다.
  - 메모리: 소리 버퍼는 효과음 종류 × 최대 4가지 변주의 짧은 모노 float(초당 약 172KB) 캐시라 유한하고 작습니다. 그래픽 240MB와는 무관합니다.
  - 끊김: 출력 장치를 다시 여는 `start()`가 수 ms ~ 수십 ms(블루투스 출력이면 더 길 수 있음) 메인 스레드를 막을 수 있고, 그 순간은 훅이 들어와 그리기가 30fps로 올라가는 때라 한두 장이 빠질 수 있습니다. **실행해 봐야 알 수 있어** 앱 안 계측에 `sound.start ms`(시작에 걸린 시간 백분위)만 더했습니다(기본 꺼짐). 2단계에서 크면 엔진을 더 오래 켜 두거나 시작을 메인 스레드 밖으로 옮기는 것을 검토합니다.

- **(6) 2단계 측정 절차 초안 (실행하지 않음)**
  - **기존 스크립트를 그대로 쓰면 안 되는 곳**: `perf-launch.sh isolated`·`normal`은 `pkill -f "Claude Office.app/Contents/MacOS"`로 **설치된 앱까지 끄고** `/Applications`의 앱을 띄웁니다. `perf.sh`는 `pgrep`의 첫 프로세스를 재므로 두 앱이 떠 있으면 어느 쪽인지 모릅니다. `perf-window.sh`는 System Events에서 프로세스 이름 "Claude Office"로 창을 찾아 **설치된 앱의 창을 누르거나 옮길 수 있고**, `open`은 Esc 키를 맨 앞 앱에 보냅니다. 같은 번들 ID로 띄우면 두 앱이 UserDefaults(`com.engyjoon.claudeoffice`: 미니 위치·투명도·디렉토리 선택·`debug.perfProbe`)를 같이 써서 서로 덮어쓰고, 새 빌드가 켜고 끌 때 `Notifier.removeAll`이 **설치된 앱이 띄운 알림까지 지웁니다**(같은 알림 센터). 계측 로그 `~/Library/Logs/Claude Office/perf.log`도 같은 파일입니다(계측은 새 빌드만 환경 변수로 켜면 섞이지 않음).
  - **더한 것(기존 모드는 그대로)**: `perf-launch.sh side-prepare`(빌드한 앱을 `build/perf/Claude Office Perf.app`으로 복사하고 번들 ID `com.engyjoon.claudeoffice.perf`·이름 "Claude Office Perf"로 바꿔 ad-hoc 다시 서명 → 설정·알림이 나뉘고, 경로가 달라 `pkill`·`pgrep` 패턴과 `make install`의 `pgrep -x`에도 걸리지 않음 — 이름만 바뀐 실행 파일 "Claude Office"는 `pgrep -x`에 걸려 그동안 `make install`이 멈춤), `side`(격리 엔드포인트 `build/perf/endpoint`·`CLAUDE_OFFICE_PERF=1`·있으면 `CLAUDE_OFFICE_BAKE_SCALE`을 넘겨 띄우고, 실행 파일 경로로 PID를 찾아 `build/perf/side.pid`에 적음), `side-stop`(그 PID의 실행 파일이 그 복사본일 때만 `kill`). `perf.sh`·`perf-window.sh`는 `PERF_PID`가 있으면 그 프로세스만 다룹니다. 복사·plist 바꾸기·다시 서명은 임시 폴더의 복사본에서 손으로 확인했고(`codesign --verify` 통과, 띄우지 않음), 스크립트 자체는 실행하지 않았습니다(`bash -n`만).
  - **절차**:
    1. `make app` → `scripts/perf-launch.sh side-prepare`.
    2. `scripts/perf-launch.sh side` → `PID=$(cat build/perf/side.pid)`. 처음이면 새 번들 ID라 환영 창·알림 권한 창이 뜰 수 있습니다(닫거나 거절). 미니는 기본 위치(화면 오른쪽 아래)에 뜹니다. 데스크톱 앱 세션은 쉬는 중으로 앉고, 실제 훅은 설치된 앱이 계속 받습니다.
    3. 상황마다 `PERF_PID=$PID scripts/perf.sh <상황> 60` — (e) 메뉴바만, (a) 미니만, (b) 사무실 창 열림 쉬는 중, (c) 바쁨(`scripts/perf-busy.sh`가 같은 엔드포인트로 보냄). 창 조작은 `PERF_PID=$PID scripts/perf-window.sh open|close|mini|mini-off`(손쉬운 사용 권한, `open`은 Esc를 보냄) 또는 손으로. 각 상황에서 `footprint $PID`와 `vmmap --summary $PID`의 그래픽 몫, `perf.log`의 `textures`·`large`·`scale`.
    4. 같은 순서를 `CLAUDE_OFFICE_BAKE_SCALE=background=1 scripts/perf-launch.sh side`로 한 번 더(앞의 것은 `side-stop`).
    5. 오래 두기: 새 빌드를 몇 시간 띄워 두고(세션이 드나들고 낮·밤이 바뀌게) 그래픽 몫이 계속 느는지 설치된 앱(같은 시간대 `footprint 48723`처럼 PID로)과 견줍니다. 설치된 앱은 읽기만 합니다.
    6. 끝: `scripts/perf-launch.sh side-stop`. `build/perf/Claude Office Perf.app`은 지워도 됩니다(새 번들 ID의 설정 `com.engyjoon.claudeoffice.perf`는 `defaults delete`로 정리).
    7. 결과를 `build/perf/results.md`와 이 항목에 적고, 목표를 "1배율 150MB / 2배율 ○○MB"로 나눠 설계서 §8.3에 적습니다.
  - **화면 배율 하나뿐이면** 1배율 값은 지난 측정(설계서 §8.3, QHD 1배율)을 기준으로 씁니다. (2)의 다시 굽기는 1배율 화면과 레티나 화면이 다 있어야 확인됩니다.

- **화면 확인 필요** (앱을 띄우지 않아 하나도 보지 못했습니다): (1) 평소처럼 사무실 창·미니가 그대로 보이는지(가구·캐릭터·말풍선이 흐리거나 빠지지 않는지). (2) 1배율 ↔ 레티나 화면으로 사무실 창·미니를 옮기면 옮긴 직후 한 장에서 캐릭터·말풍선·가구가 새 배율로 선명해지고 깜빡이거나 사라졌다 나타나지 않는지, 고른 직원 외곽선이 남는지, VoiceOver가 "레이아웃 바뀜"을 읽지 않는지. (3) 사람이 많고 롤러가 도는 사무실에서 몇 분 지나도 끊김이 없는지(캐시 400장). (4) `perf.log` 첫 줄의 "텍스처 배율"과 `textures … scale …`이 장면 배율을 보이는지.

**결과 — 2단계** (2026-11-12, 사용자 승인 뒤 실측. 커밋 `4a7a7a8`·`f6c0774`): `make test` 524개 통과, `make app` 통과, `make snapshot` SVG 14장 바이트 동일.

- **환경과 한계**: Apple M3 + LG UltraFine 5K(2560×1440 @2배율) 하나. 1배율 화면이 없어 1배율은 재지 못했습니다. **측정하는 동안 화면이 잠겨 있고 디스플레이가 꺼져 있었습니다**(밤 23시~0시, `CGDisplayIsAsleep`·`CGSSessionScreenIsLocked`로 확인). 그래서 사무실 창은 열렸지만 가려진 것으로 쳐져 한 장도 그려지지 않았고(`perf.log` office paused 100%), **보이는 상태의 그리기 몫(그림판 2장, 화면 렌더러)은 들어 있지 않습니다**. 굽기는 그리기와 상관없이 일어나므로 아래 차이는 그대로 유효합니다. 효과음은 사무실이 보일 때만 울려서 재지 못했습니다.
- **처음 실측(326MB)과 바로 견줄 수 없는 점**: 그것은 3시간 41분 실행 뒤 값이고, 이번 측정은 한 번에 3~8분입니다. 참고로 같은 맥에서 돌던 설치된 앱(옛 빌드)은 8시간 23분 뒤 311MB(그래픽 203MB, `footprint`로 읽기만 함)였습니다. 짧은 측정에서는 시간이 지나도 늘지 않았고(아래 churn 8분 그대로), 오래 둘 때 느는지는 확인하지 못했습니다.
- **방법**: 빌드한 앱 실행 파일을 직접 띄워(`$!`가 PID) 그 PID만 `kill`로 끝냈습니다. 격리 엔드포인트, `CLAUDE_OFFICE_PERF=1`, 새 측정 설정 `CLAUDE_OFFICE_PERF_SCENE`(menubar·mini·office, 저장 안 함, 아래)과 앱 인자 `-sound.enabled NO -office.selection.all YES`(인자 도메인이라 저장 안 됨)로 상태를 만들었습니다. 창 조작(System Events)은 쓰지 않았습니다. 짐은 `office-sim replay`로 격리 엔드포인트에만(crowd = `floor.jsonl` 한 번, churn = `floor`·`delegation` 4배속 반복). 기준선은 `6c7119a`에 측정 설정 패치만 얹어 스크래치 worktree에서 따로 빌드했고 두 빌드를 동시에 띄우지 않았습니다(worktree·빌드는 지움). 시작 전·각 실행 뒤에 설치된 앱 PID 48723, 기본 엔드포인트 파일과 `~/.claude/settings.json`의 해시를 확인했고 끝까지 같았습니다. 원자료는 `build/perf/results.md`와 공유 노트 폴더 `improve-10-stage2-runs`.

  | 상태 (footprint MB, 60초 뒤) | 기준선 `6c7119a` | 1단계 | 뷰 없으면 안 굽기 | + 큰 층 CoreGraphics·투명도 층 자르기 (지금 기본) |
  |---|---|---|---|---|
  | 메뉴바만 | 196 (그래픽 173) | 196 | **19** (그래픽 0) | 19 |
  | 미니만 | 205 (그래픽 179) | 205 | **31** (그래픽 7) | 31 |
  | 사무실 창 열림·쉬는 중 | 298 (그래픽 243) | 298 | 245 (그래픽 191) | — |
  | 사무실 창 + 18명 (crowd) | 299 (그래픽 243) | 299 | 245 | **117** 밤 / **105~127** 낮 (그래픽 59~64) |
  | 사무실 창 + churn 8분 | 299 → 299 | 299 → 300 | 246 → 246 | 117 → 117 |

  그래픽 = unmapped(graphics) + IOAccelerator(graphics) + IOSurface. 20초 값은 굽기 직후라 30MB쯤 높고 60초에 내려앉습니다(사무실 150 → 117).

- **어디가 컸나 (1단계 계산과 견줌)**: 계산한 텍스처는 2배율 사무실 창 약 50MB였는데, 실측의 큰 몫은 텍스처가 아니라 **큰 층을 GPU로 굽던 화면 밖 `SKView`**였습니다. 2배율 바탕(350만 픽셀)은 100만 픽셀 기준을 넘어 `SKView.texture(from:)`로 구웠고, 그때마다 큰 층 텍스처(약 33MB)보다 훨씬 많은 그래픽 메모리(unmapped +73MB, IOAccelerator +40MB, 합 약 113MB)가 잡혀 내려가지 않았습니다. 같은 층을 CoreGraphics로 구우면 텍스처는 IOAccelerator에만 남고 CPU 사본(`CG image`)은 0.1MB였습니다(M6(1)의 "CPU 사본 50MB"는 이 맥에서 재현되지 않음). 게다가 앱을 켤 때 `SKScene.init(size:)`의 크기 변경으로 **보이지 않는 사무실·미니 장면도 바탕을 GPU로 구워**, 메뉴바만 있어도 그래픽 173MB였습니다. 1배율 화면에서 메뉴바만 27MB였던 것(설계서 §8.3)은 1배율 바탕이 100만 픽셀 아래라 GPU 경로를 타지 않았기 때문입니다.
  - 1단계의 다른 후보: 캐시에 쌓인 몫은 크지 않았습니다(사무실 창 캐시 약 11~25MB, 32MiB 상한 안). 창 백버퍼 추정(19MB)은 IOSurface 35MB 안에 들어갑니다(사무실 창이 열린 모든 경우 35MB 그대로, 그림판은 그려지지 않아 미확인).
- **고친 것 (기본 동작이 바뀜)**:
  1. **뷰에 붙지 않은 장면은 굽지 않음** (`OfficeScene.sync`): 처음 보일 때 `didMove(to:)`가 굽습니다. 메뉴바만 196 → 19MB, 미니만 205 → 31MB.
  2. **큰 층도 CoreGraphics로 굽고 캐시하지 않음** (`ShapeBaker`): 화면 밖 SKView 경로는 측정용 `CLAUDE_OFFICE_GPU_BAKE_PIXELS=1000000`로만 켭니다(예전 방식과 견주기용, 같은 빌드에서 사무실 246 vs 117MB로 확인). 화질 근거: 다른 모든 층과 1배율 화면의 바탕이 이미 같은 CoreGraphics 굽기를 써 왔으므로 2배율 바탕만 다른 래스터라이저(SKShapeNode)로 그리던 것이 같아지는 쪽입니다. 그래도 화면 확인 필요.
  3. **투명도 층을 도형 경계로 자름**: CoreGraphics 투명도 층은 잘린 영역만큼 버퍼를 만들어, 반투명 도형 하나마다 350만 픽셀 버퍼를 만들고 합치고 있었습니다. 처음 CoreGraphics로 바꿨을 때 밤 바탕 굽기가 **660~950ms(메인 스레드)**였고, 도형 경계(+ 선 굵기·1pt)로 자르자 앱에서 15~33ms(디버그 벤치 622 → 12ms, 낮 65 → 3ms)가 됐습니다. 결과 픽셀은 같습니다(스냅샷은 SVG라 이 수정과 무관). 1배율 화면의 굽기도 같이 빨라집니다. 예전 GPU 경로는 15~100ms였습니다.
- **켜지 않은 것**:
  - **바탕 1배율 굽기**(`CLAUDE_OFFICE_BAKE_SCALE=background=1`): GPU 경로가 있던 때는 299 → 183MB였지만 그것은 GPU 경로를 피한 효과였고, 지금 기본 위에서는 117~126MB로 **줄지 않았습니다**(1배율 바탕은 100만 픽셀 아래라 캐시에 들어감). 화질만 잃으므로 기본은 그대로 화면 배율.
  - **그림판 배율**(`CLAUDE_OFFICE_DRAWABLE_SCALE=1`, `CAMetalLayer.contentsScale`): 차이 없음(299 vs 299). 다만 화면이 꺼져 한 장도 그리지 않아 그림판이 만들어지지 않았을 수 있어 **판단하지 못했습니다**. 측정 설정으로만 남겨 둡니다.
- **`SoundPlayer`**: 재지 못했습니다(효과음은 사무실이 보일 때만 울림). 계측 `sound.start ms`는 들어가 있습니다.
- **측정용으로 더한 것** (`PerfLaunch`, 평소 동작 그대로): `CLAUDE_OFFICE_PERF=1`이면 알림 센터를 건드리지 않음(켤 때·끌 때 지우기, 권한 묻기, 보내기 — 설치된 앱과 같은 번들 ID라 그 앱의 알림을 지우지 않게), 미니 위치·첫 실행 표시를 저장하지 않음, `CLAUDE_OFFICE_PERF_SCENE`, `CLAUDE_OFFICE_DRAWABLE_SCALE`, `CLAUDE_OFFICE_GPU_BAKE_PIXELS`. 계측에 `bake.large ms`.
- **설치된 앱에 남은 영향**: 설정 도메인(`com.engyjoon.claudeoffice`)을 측정 전에 보관해 두고 끝에 견줬습니다. 달라진 키는 **`NSWindow Frame office` 하나**(`518 338 1441 866` → `518 308 1441 896`)입니다. SwiftUI가 사무실 창 위치를 스스로 저장하는 키이고, 측정 앱의 창이 30pt 더 높았습니다(격리 엔드포인트라 훅 연결 경고 띠가 붙었을 것). 설치된 앱이 실행 중이라 되돌리지 않았습니다. 사무실 창은 내용 크기로 고정이라 다음에 열 때 위치만 30pt 위일 수 있습니다. 알림은 측정 빌드가 건드리지 않았습니다. 측정 앱이 사무실 창을 띄울 때마다 앞으로 가져오지만, 화면이 잠겨 있어 보이지는 않았습니다.
- **목표**: 설계서 §8.3에 "1배율 150MB / 2배율 200MB"로 나눠 적었습니다. 2배율 200MB의 근거는 화면이 잠긴 상태의 사무실 창 실측 117MB에 보이는 상태의 그림판 2장(계산 27MB)과 화면 렌더러 몫의 여유를 더한 것입니다. **보이는 상태와 몇 시간 실행 뒤 값은 다시 재야 합니다**(화면 확인 필요).
- **화면 확인 필요**: (1) 레티나에서 사무실 창 바닥·벽·러그·밤 불빛이 예전과 똑같이 선명한지(GPU → CoreGraphics). (2) 처음 여는 사무실 창·미니가 바로 그려지는지(뷰에 붙을 때 굽기). (3) 명패가 바뀌거나 낮·밤이 바뀔 때 끊김이 없는지(`bake.large ms`). (4) 화면이 켜진 상태에서 상태별 `footprint` — 이번 절차(`measure.sh`, 공유 노트 폴더)를 낮에 다시 돌리면 됩니다. 오래 두었을 때 느는지도.

## 11. 구조 정리와 안전망

**문제 (코드)**: 같은 규칙이 여러 곳에 복사돼 있고 이미 어긋났습니다. 동작을 바꾸지 않는 정리입니다.

- **`AppModel`(960줄)**: "엔진이 바뀐 뒤" 처리(기록 → 알림 → 직원 목록 → 미니 초점 → 선택 정리 → 현황 줄)가 네 곳에 복사돼 있고, tick 경로는 일부만 합니다. (`App/Sources/AppModel.swift:309-312`, `:340-357`, `:416-423`, `:491-506`) `settleUntil` 올리기가 네 가지 꼴입니다. (`:371`, `:412`, `:445`, `:807`) 사무실 창을 제목으로 찾는 코드가 여섯 곳입니다.
- **훅 본문을 메인 스레드에서 두 번 파싱**: `engine.handle`과 `summary(of:)`. 전달 큐에서 한 번만 파싱할 수 있습니다. (`AppModel.swift:344-345`, `:945-958`)
- **`Choreographer`(1030줄)**: 상태 → 모습(자세·소품·표정·이모트) 규칙이 `show`·`rest`·`settle`·`restoreRest`·`restored*`에 따로 있어, 웹 검색 중인 직원이 다시 앉으면 자세가 바뀌고 음료가 컵으로 바뀝니다. (`Sources/OfficeCore/Engine/Choreographer.swift:658-660`, `:787`, `:561-571`, `:836-838`)
- **`OfficeLayout` ↔ `OfficeArt` 숫자**: 책상 발자국, 벽 선 160, 소파·액자 좌표, 머리 위치가 양쪽에 숫자로 적혀 있습니다. 길찾기 여유는 1pt입니다. (`Sources/OfficeStage/OfficeLayout.swift:311`, `:342`, `Sources/OfficeStage/Art/OfficeArt.swift:79-81`, `:362-363`, `:480-489`)
- **중복**: 글자 폭 재기 두 벌(`OfficeArt.estimatedWidth`와 `TextMetrics.width`), "최근 활동" 정의 세 벌, `OfficeFloor.apply`와 `resync`, `Stage`의 `.despawn`과 `remove`.
- **죽은 코드**: `OfficeLayout.lounge`·`wallBottom`, `Pathfinder.length`, `RenderPacer.isLively`, `MiniFocus.next(pinned:)`, 앱이 읽지 않는 `StageEvent`들, 쓰이지 않는 `OverlayTier.tiny`·`.compact`.
- **잠복 버그**: `VectorPath`가 "Z" 뒤 숫자에서 무한 루프(`Sources/OfficeStage/VectorPath.swift:84-87`), `abs(hash)`가 `Int.min`에서 죽음(`Sources/OfficeStage/Art/CharacterArt.swift:516`).
- **안전망**: 앱 계층은 Swift 5 모드·동시성 검사 최소이고(`App/project.yml:48-50`), 테스트와 CI가 없습니다.

**고칠 방향**: `AppModel`에 `commit(_ directives:, at:)` 하나를 두고 네 경로가 쓰게 합니다. `Choreographer`에 순수 함수 `look(for:)` 하나를 둡니다. 배치 숫자는 `OfficeLayout`에서만 정의하고 그림이 읽어 갑니다. 중복과 죽은 코드를 걷어 냅니다. `make test`만 도는 GitHub Actions 워크플로 파일을 더합니다(푸시는 사용자 몫). 앱 계층의 Swift 6 전환은 범위가 커서 가능한지 조사만 하고 결과를 적습니다.

**완료 기준**: 스냅샷이 정리 전과 같고(`make snapshot` 결과 비교), `make test`·`make app`이 통과합니다. 커밋은 덩어리별로 나눕니다.

**결과** (2026-11-11, 커밋 `c77d48d`·`0169f03`·`bea70b7`·`e9ab6b0`·`33353e8`·`489d1f1`·`69b1497`·`5d838b5`):

- **기준선**: 정리 전(`2ce960e`)에 `make snapshot`의 SVG 14장, 밤 5장(`delegation --at 2.6,20,52.2,128,400 --night`), `make demo` 출력, 그리고 덤으로 나머지 시나리오 다섯(`crowd`·`layout`·`rooms`·`notify`·`m0-observed`)의 스냅샷과 지시 타임라인까지 50개 파일을 보관하고(두 번 돌려 같은 결과임을 확인), 덩어리마다 바이트 단위로 비교했습니다. 덩어리 1~4·6·7과 파일 나누기는 50개가 그대로이고, 덩어리 5만 3장이 달라졌습니다(아래). `make test`는 504 → 516개 통과, `make app` 통과.
- **(1) 잠복 버그**: `VectorPath.parse`는 "Z" 뒤에 숫자가 오면 그 숫자를 먹지 못해 같은 자리를 끝없이 돌며 `close`를 쌓았습니다 → 거기서 멈춥니다(시간 제한을 건 테스트). `StableHashLite.value`의 `abs(hash)`는 `Int.min`에서 넘쳐 죽습니다 → 그 값만 0(`nonNegative`, 나머지는 `abs`와 같은 값이라 깜빡임 시점·별 자리는 그대로).
- **(2) 죽은 코드**: 지운 것 — `OfficeLayout.lounge`, `Pathfinder.length`(쓰던 테스트 하나 안으로 옮김), `RenderPacer.isLively`(테스트는 `motion`을 봄), `MiniFocus.next(pinned:)`와 `Reason.pinned`·`office-sim --pin`(앱은 늘 nil), `StageEvent.effect`, 미니 패널의 `windowDidResize`(크기 고정, 프로그램이 바꿀 때는 `placing`이라 일하지 않음), `AppModel.missingHookEvents`(읽는 곳 없음).
  - **남긴 것과 까닭**: `OfficeLayout.wallBottom`은 덩어리 4에서 그림이 읽어 가는 값이 됐습니다. `StageEvent`의 `.teamOpened`·`.teamClosed`·`.spawned`·`.despawned`는 앱은 안 읽지만 테스트가 "그 사이 무대에서 내려간 적이 없다"(`busyRowsStay` 등)를 확인하는 기록이라 남기고 주석에 적었습니다. **`OverlayTier.tiny`·`.compact`는 죽은 코드가 아니었습니다**: 화면이 작으면 사무실 영역을 줄이므로(`OfficeWindowSize.office(screen:)`, 최소 480×300) 예컨대 화면 폭 1200pt 이하에서 패널을 연 채면 배율이 0.8 아래로 내려가 `.compact`(칩 숨김·18자)가 실제로 나옵니다. 그대로 두었습니다.
- **(3) 무대 쪽 중복**: `Stage`의 `.despawn`과 `remove` → `takeDown`(자리 예약 풀기·말풍선 올리기·닫히던 행 닫기), `OfficeFloor.apply`와 `resync` → `replan`(배치 다시 세우고 숨은 사람 내리고 행·칸 맞추기)·`restoreNewlyVisible`, 팀 색 `% count` 네 곳 → `Swatch.team(_:)`, "응답을 끝낸 때"(`completedAt ?? activitySince`) 세 곳과 "행의 마지막 요청" 두 곳 → `OfficeState.completedAt(of:)`·`lastPromptAt(in:)`.
  - **"최근 활동" 세 벌**은 뜻이 서로 달라 합치지 않았습니다: 행의 마지막 활동(`FloorPlan.lastActivity`: 활동 바뀐 때·요청), 서브의 마지막 활동(`MiniCast.pick`: 활동 기록까지 봄), 행의 마지막 요청(`MiniFocus.status`). 똑같이 복사돼 있던 위 두 조각만 옮겼습니다.
  - **글자 폭 두 벌은 그대로 두었습니다**: `OfficeArt.estimatedWidth`(명패·"+N", 한글 1.0·영문 0.52)를 `TextMetrics.width`(한글 0.87 등)로 바꾸면 명패가 있는 스냅샷이 전부 달라집니다("★ 메인1" 명패 폭 48.3 → 45.3pt, "서브N"·"+N"도 1~3pt). 같은 규칙의 사본이 아니라 "넉넉하게 잡은 어림"과 "실제 글꼴에 맞춘 어림"이라, 합치려면 맥 화면에서 글자가 좁아진 명패 안에 들어오는지 봐야 합니다(아래 "새로 발견한 것").
- **(4) 배치 숫자**: `OfficeLayout`에서만 정의하고 그림이 읽어 갑니다 — 벽과 바닥의 경계 `wallBottom`(바탕·걸레받이·줄눈·현관 매트·출입문), 책상 `deskTop`·`deskBottom`·`deskFootprint`(그림의 상판·앞판과 장애물, 명패 최대 폭, 행 표지 위치), 행 띠 `rowAbove`·`rowBelow`(미니 사무실 아래 끝), 소파 `sofaSeatOffsets`·`sofaSeatY`·`sofaApproachY`(앉는 판 칸막이·깊이), `whiteboardWidth`·`doorWidth`·`pantryWidth`(최소 폭 계산·출입문 자리·그림), 길찾기 여유 `obstacleMargin`, 머리 꼭대기 `CharacterArt.crown`(`Overlay.headTop`·`badgeOffset`). 테스트: 기본 크기와 최소 크기에서 모든 접근 지점(책상 뒤, 공용 구역 앞, 출입문)이 가구 밖이고 걸을 수 있는 칸임(`approachesAreWalkable`), 첫 행 책상 뒤 여유가 정확히 1pt이고 그림의 책상과 장애물이 같은 폭·같은 위 끝임(`deskApproachMargin`).
- **(5) 모습 규칙**: `Choreographer.look(for:)`(순수 함수, 자세·손에 든 것·표정·늘 따라붙는 아이콘) 하나를 `show`·`rest`·`settle`·`restoreRest`·자리 옮김(`returnToOwnDesk`)·손 내리기(`resolveWaiting`)·`restoreDirectives`·긴 명령 ⏳·정리 중·승인 요청이 씁니다. `restoredPose`·`restoredProp`·`restoredExpression`·`currentPose`는 없앴습니다. 지시를 내는 순서는 자리마다 예전 그대로라 `make demo` 출력은 바이트까지 같습니다. **어긋났던 곳은 모두 "일할 때 낸 모습" 쪽으로 맞췄습니다** (다시 세우거나 자리를 옮길 때가 달라짐):
  - 웹 검색: 다시 세우거나 자리를 당겨 앉으면 읽는 자세 → **타이핑** 그대로.
  - 냉장고에서 꺼낸 음료: 소파에서 대화를 정리한 뒤·다시 세울 때 컵 → **음료** 그대로(`Presence.drink`).
  - 긴 셸 명령을 기다림(⏳): 다시 세우면 집중한 표정 → **평온한 표정**, 책상이 아니면 타이핑 → 생각하는 자세.
  - 화이트보드 앞에서 계획을 마치고 생각 중·잠깐 머무는 중: 다시 세우면 판서 자세와 마커 → **생각하는(서 있는) 모습, 빈손**.
  - 승인을 기다리는 사람은 어디에 있든 손 든 모습(안마 의자에서 다시 세우면 안마 자세였음), 응답이 끝난 뒤 남아 있던 ⏳ 표시로 모니터 보는 자세가 되던 것은 앉아 쉬는 모습.
  - 달라진 스냅샷 3장: `floor-052`·`floor-080`(`swift build`를 기다리다 화면에 다시 들어온 서브의 표정), `mini-065`(웹 검색 서브의 팔 자세, `swift test`를 기다리는 서브의 표정). 테스트 `LookTests` 7개(웹 검색·당겨 앉기·음료·긴 명령·화이트보드·쉼 단계·승인 대기).
- **(6) `AppModel`**: `commit(_:at:)` 하나가 지시를 무대에 넘기고 → 알림 → 직원 목록 → 미니 초점 → 고른 사람 정리 → 현황 줄을 하고, `receive`·`sweepEndedProcesses`·`syncResidents`·`acknowledge`·tick이 모두 이것을 부릅니다. **tick 경로**: `OfficeEngine.tickChanges`(tick이 상태를 바꾼 횟수, 테스트)가 달라졌을 때만 `commit`이라, 출근 중 → 쉬는 중·정리 중 시간 초과·1시간 침묵이 다음 훅이나 5초 확인을 기다리지 않고 목록·현황 줄·알림에 바로 반영됩니다. 연출만 흘러가는 tick은 예전처럼 지시를 무대에 넘기고 미니 초점만 봅니다(0.25초 구간에서 정수 하나 비교). `settleUntil` 올리기 네 꼴 → `keepLively(for:from:repace:)`, 사무실 창을 제목으로 찾던 곳 → `OfficeWindow`(`owns`·`first(where:)`·`isOpen`·`isOpenOrMinimized`·`close`), 훅 본문은 전달 큐에서 `ParsedHook`으로 한 번만 파싱(로그 한 줄도 그때 만듦).
  - **함께 달라진 동작(작음)**: 응답 확인(`acknowledge`)도 알림 큐·고른 사람 정리·현황 줄까지 맞춥니다. 지시를 받을 때 `settleUntil`을 덮어쓰지 않고 더 긴 쪽을 지킵니다(조명 크로스페이드 중에 훅이 와도 30fps 유지). 읽을 수 없는 훅에서도 쌓인 알림 동작을 비웁니다.
- **(7) 안전망**: `.github/workflows/test.yml` — 푸시·PR마다 `macos-26` 러너에서 `swift --version`과 `make test`. **실제로 도는지는 확인하지 못했습니다**(푸시는 사용자 몫). 러너 이름이 없다고 나오면 `macos-15`(Xcode 16, Swift 6.x; `Package.swift`는 tools 6.0)로 바꾸면 됩니다. 로컬은 Xcode 26.1.1·Swift 6.2.1입니다.
  - **앱 계층 동시성 조사** (설정은 되돌림, 전환하지 않음): Swift 5 모드에서 `SWIFT_STRICT_CONCURRENCY: complete`로 올리면 **오류 0개, 앱 소스 경고 91개**(중복 제외)입니다. 파일별로 `OfficeScene` 46·`SceneAccessibility` 20·`ShapeBaker` 14·`Notifier` 6·`ClaudeOfficeApp` 3·`Support` 1·`AppModel` 1(파일을 나누기 전 기준). 종류는 "메인 액터 속성·메서드·생성자를 격리 안 된 곳에서 씀"이 67개(`SKScene`·`SKNode` 하위 클래스와 `StageStore`에 `@MainActor`가 없어서 생김), 전역 변경 가능 상태(`ShapeBaker`의 캐시 등) 7개, `sending`·Sendable 아닌 값 캡처·기타가 17개입니다. `SWIFT_VERSION: 6.0`으로 올리면 첫 묶음에서 오류 9개(`ShapeBaker` 5·`OfficeScene` 2·`ClaudeOfficeApp` 2)로 멈추고, 위 경고 대부분이 오류가 됩니다. 전환한다면 `StageStore`·`OfficeScene`·`CharacterNode`·`ArtNodes`·`ShapeBaker`에 `@MainActor`를 다는 것이 대부분이고(`ShapeBaker`는 10번이 고치는 파일이라 그 뒤에), `Notifier`의 대리자 콜백 정리가 남습니다.
- **파일 나누기 (코드 이동만, `5d838b5`)**: `OfficeState.swift`(1011줄) → 본체(저장 속성·조회·리듀서·압축·공통, 477줄) + `OfficeState+ImplicitEnd`·`+Cues`·`+Residents`·`+Rooms`·`+Members`. 다른 파일의 확장이 쓰도록 `private` 멤버와 `private(set)` 저장 속성을 모듈 내부(`internal`·`internal(set)`)로 넓힌 것 말고는 줄 단위로 같습니다(옮긴 줄을 원본과 대조). `OfficeScene.swift`(1073줄) → `OfficeScene`·`StageStore`·`CharacterNode`·`ArtNodes`(`OverlayNode` 포함).
- **설계서**: §6.4(모습 규칙), §8.1(배치 숫자 정의 위치와 접근 지점 불변식), §8.3(모델 타이머: `commit`과 tick), §10.1(미니 고정 인자 제거), §13(저장소 구조), §14.2(CI·기준선).
- **화면 확인 필요** (설치된 앱은 바꾸지 않았습니다): (1) 새 세션이 출근한 지 10초 뒤 패널·메뉴의 "출근 중"이 훅 없이도 "쉬는 중"으로 바뀌는지. (2) 미니 사무실·디렉토리 전환으로 다시 세워진 직원: 웹 검색 중이면 타이핑, 냉장고 음료를 든 채 소파, ⏳로 기다리는 사람의 표정. (3) 사무실 창에서 직원을 고를 때 발밑 고리가 바로 그려지는지, 밤·낮 전환 크로스페이드가 훅이 오는 중에도 끊기지 않는지. (4) 미니 → 사무실 창 전환, 사무실 창을 닫으면 미니가 다시 뜨는지, Esc로 고른 직원 해제(`OfficeWindow`로 옮긴 창 찾기). (5) 이벤트 로그의 훅 한 줄이 예전과 같은 모양인지.

---

## 화면 점검 (2026-11-16)

새 빌드(`3b8a48e`)를 설치해 4일 9시간 돌린 앱을, 화면 기록·손쉬운 사용 권한을 받아 직접 찍어 보며 확인했습니다. 5K 2배율 화면 하나, 낮 시간, 실제 세션 12개(직원 26명)가 있는 상태입니다. Claude Office 창만 찍었고, 조작은 메뉴바 아이콘·사무실 창·설정·이벤트 로그에만 했습니다.

**확인한 것 (정상)**

| 항목 | 본 것 |
|---|---|
| 10 그리기 품질 | 사무실 창의 벽·걸레받이·바닥 줄눈·가구·캐릭터·글자가 2배율 원본 크기에서 선명함(낮). 처음 여는 사무실 창과 미니가 바로 그려짐 |
| 8 칩 | 칩이 제 머리 위 한 줄로 말줄임("Bash · S=scratchpa…"), 마우스를 올리면 전체로 펼쳐져 옆 사람 위를 덮고, 고르면 전체 + ▼ + 몸 외곽선, Esc로 풀면 다시 줄어듦 |
| 8 표지 | 같은 폴더 세션 둘의 행 표지 둘째 줄에 세션 제목이 나옴 |
| 8 메뉴바 | 주황 느낌표(오른쪽 위)와 상태 점(오른쪽 아래)이 겹치지 않음 |
| 9 경과 시간 | 미니 "답변 필요 · 4일 전", 패널 "4일 15시간째", 현황 줄 "(4일 전)" |
| 4·11 상태 반영 | 임시 세션의 SessionStart만 보낸 뒤 3초에 "출근 중"(문에서 걸어옴), 14초에 훅 없이 "쉬는 중". SessionEnd 뒤 인원이 원래대로 |
| 11 창 동작 | 사무실 창을 열면 미니가 사라지고 닫으면 다시 뜸. 직원 고르기·Esc 해제. 이벤트 로그 줄 모양("PreToolUse Bash · claude-office · 데스크톱 메인") |
| 1·6·7 연동 | 설정 → 연동이 모두 초록(이벤트 14개, 스크립트 있음·실행 가능, 서버 실행 중, 엔드포인트 "이 앱의 포트·토큰", Claude Code 2.1.321). 사무실 창에 경고 띠 없음. 인스펙터의 "Claude 데스크톱 앱 [앱으로]" |
| 3 가림 | 현황 줄·칩·패널의 명령에서 스크래치 경로가 `scratchpad`로 줄어 보임 |

**확인하지 못한 것**

- 밤 장면(♪·Zz·빛줄기, 밤 불빛 선명도): 낮이라 보지 못함. 조명을 강제로 바꾸는 설정이 없음.
- 소파 바깥 자리, 다시 세워진 직원의 모습(웹 검색·음료·⏳), 답변 필요만 남았을 때의 파란 점: 그 상황이 없었음.
- 세션 4개 이상이 함께 일할 때의 행 전환, 미니 초점 전환: 가짜 세션을 여럿 보내야 해서 하지 않음.
- 이벤트 로그를 위로 올려 읽는 중의 따라가기, 설정의 "테스트 이벤트 보내기"(자동 조작이 버튼을 찾지 못함).
- 1배율 ↔ 레티나 이동, 실제 `kill -9` 퇴근, Esc 중단 뒤 입력 대기, 서브의 승인 요청, Cursor·터미널 이동, 알림 권한, 환영 창, Dock 크기, VoiceOver·효과음: 장비나 실제 상황이 필요함.

**메모리 (10번의 "보이는 상태" 재측정)** — `footprint`, 같은 프로세스에서 차례로

| 상태 | 값 |
|---|---|
| 4일 9시간 실행, 사무실 창을 한 번도 열지 않음 (미니만) | 88MB (새로 켠 직후는 31MB) |
| 사무실 창을 연 직후 | 최대 325MB (MALLOC_LARGE 69MB·CG image 30MB가 1분 안에 내려감) |
| 사무실 창이 보이는 상태, 30~90초 | **252MB** (unmapped graphics 74 · MALLOC_SMALL 46 · IOSurface 39 · IOAccelerator 29 · CG image 27 · CoreAnimation 16) |
| 사무실 창이 다른 창에 완전히 가려진 상태 | 162MB (장면이 멈추고 텍스처를 놓음) |
| 사무실 창을 닫고 2분 뒤 (미니만) | **256MB** (unmapped graphics 74 · IOSurface 41이 그대로) |

- 10번 2단계의 117MB는 화면이 잠겨 한 장도 그리지 않은 값이었습니다. 실제로 보이는 상태는 252MB로 **2배율 목표 200MB를 넘습니다**. 옛 빌드의 같은 조건 값은 없어 바로 견줄 수 없습니다(옛 빌드 실측은 299~326MB).
- 사무실 창을 한 번 열면 닫아도 메모리가 돌아오지 않습니다(88 → 256MB). 사무실 창을 열지 않고 쓰는 동안의 이득(196 → 19~88MB)은 그대로입니다.

## 새로 발견한 것

(항목을 진행하다 범위 밖에서 발견한 문제를 여기에 적습니다.)

4번 항목을 하다가 (2026-11-11):

- **`PostToolBatch` 훅** (2.1.321 실행 파일에 있음: "한 묶음의 도구가 모두 끝난 뒤, 다음 모델 요청 전에 한 번"). 설치 목록에 넣고 파서가 받으면 도구 묶음의 경계를 정확히 알 수 있어 4번의 "2초 간격" 추정을 대신할 수 있습니다. 설치 목록·버전 조건은 1·7번 범위입니다. (`Sources/OfficeCore/Hooks/HookSettingsEditor.swift`, `HookParser.swift`)
- **기본 9종만 설치돼 있으면 실패한 도구에 끝 이벤트가 없습니다** (`PostToolUse`는 성공만). 1번의 "다시 설치"로 `PostToolUseFailure`가 들어가기 전까지 이 맥에서는 오류 연출(💦)이 나오지 않고 4번의 묶음 규칙이 뒷정리만 합니다.
- **파서가 버리는 알림 종류**: 2.1.321의 `notification_type`에 `worker_permission_prompt`·`agent_needs_input`·`agent_completed`가 있습니다. 서브·워커의 승인 요청이 `worker_permission_prompt`로 올 수 있다면 지금은 무시됩니다. 실제 페이로드를 수집해 봐야 합니다. (`HookParser.swift:114-129`)
- **tick에서만 바뀐 상태가 앱에 늦게 보임**: `AppModel.frame()`은 `engine.tick`의 지시만 무대에 넘기고 명단·현황 줄·알림은 고치지 않아, 압축 시간 초과·출근 중 → 쉬는 중·1시간 규칙이 다음 훅이나 5초마다 도는 `syncResidents` 때 반영됩니다. 11번의 `commit(_:at:)` 통합에서 tick 경로도 같이 태우면 됩니다. (`App/Sources/AppModel.swift:316`, `:502`)
- **시나리오가 실제와 다른 곳**: `Scenarios/mini.jsonl` 14.2초의 `Notification`에 `agent_id`가 실려 있지만 실제 알림에는 없습니다(4번 전제 확인). 지금 동작에는 영향이 없습니다.
- **죽은 터미널 세션이 자리에 남음**: PID 확인 방식으로 7번 항목에 넣었습니다 (사용자 결정).

6번 항목을 하다가 (2026-11-11):

- **사무실 창 Return 키의 `where`**: `OfficeSKView.keyDown`의 `case 36, 76 where modifiers.isEmpty`는 `where`가 76(Enter)에만 걸려, 수식키를 누른 Return도 이동을 합니다(빌드 경고). 9번(잔손질)에서 `case 36 where …, 76 where …`로 나누면 됩니다. (`App/Sources/ClaudeOfficeApp.swift`의 `keyDown`)
- **Cursor 세션 구별**: 훅 스크립트가 `__CFBundleIdentifier`를 함께 보내면 VS Code·Cursor·Insiders를 구별할 수 있습니다. 스크립트 변경은 다시 설치가 필요하므로 7번에서 판단합니다.

7번 항목을 하다가 (2026-11-11):

- **`PostToolBatch` 훅**: 실제 페이로드를 수집하지 못해 이번에도 넣지 않았습니다(위 4번 항목의 내용 그대로).
- **인스펙터·메뉴 버튼 도움말의 앱 이름**: 이동 동작(`AppModel.focusAgent`·알림 열기)은 띄운 앱의 번들 id를 쓰지만, `AgentCard`·`MenuContentView`의 버튼 도움말은 아직 `row.destination`이라 Cursor 세션에도 "VS Code 창을 앞으로 가져와요"라고 씁니다. `model.destination(for:)`로 바꾸면 됩니다(9번 문구 쪽).
- **tmux 안의 세션**: `TERM_PROGRAM=tmux`라 버튼이 없지만, 번들 id(`__CFBundleIdentifier`, 예: iTerm)로 바깥 터미널은 알 수 있습니다. 버튼을 보이려면 번들 id가 `RosterRow`까지 와야 해서(코어 모델 변경) 넣지 않았습니다.

11번 항목을 하다가 (2026-11-11):

- **명패 글자 폭을 `TextMetrics`로 합치기**: `OfficeArt.estimatedWidth`(명패·"+N")는 `TextMetrics.width`보다 넉넉한 다른 어림입니다. 합치면 명패가 1~3pt 좁아지므로, 맥 화면에서 굵은 9.5pt 글자가 좁아진 명패 안에 들어오는지 확인한 뒤에 합칠 수 있습니다(8번의 NFC·grapheme 기준도 그때 명패에 적용됨). (`Sources/OfficeStage/Art/OfficeArt.swift`의 `estimatedWidth`·`fitted`)
- **손을 든 동안 들고 있던 책·서류**: 승인 요청(`permissionAsked`)은 자세·표정·"!"만 바꾸고 손에 든 것은 내리지 않아, 책을 읽다 승인을 기다리면 책을 든 채 손을 듭니다. 화면에 다시 세우면(`look(for:)`는 빈손) 책이 사라집니다. 어느 쪽이 맞는지 정해 한쪽으로 맞추면 됩니다(지시 한 줄 차이라 `make demo` 출력이 달라짐). (`Sources/OfficeCore/Engine/Choreographer.swift`의 `permissionAsked`)
- **쉬는 자리에서 생각 중으로 바뀌면 깨우지 않음** (코드): 소파·안마 의자에 조용히 앉힌 데스크톱 세션의 첫 훅이 도구의 끝(Post)이면 `offer(.thinking)` → `show(.thinking)`이 `wake` 없이 생각하는 자세만 내서, 다음 도구가 올 때까지 소파에서 ♪를 띄운 채 생각합니다. `show(.thinking)`도 일하는 중처럼 깨워 자리로 보내면 됩니다. (`Choreographer.show`)
- **앱의 색 표 사본**: `App/Sources/Support.swift`의 `Palette.tops`·`skins`·`teams`가 `CharacterArt.tops`·`skins`, `Swatch.teamColors`와 같은 값을 따로 적어 둡니다(패널 칩·초상화 색). 지금은 값이 같지만 한쪽만 바꾸면 사무실과 패널의 색이 어긋납니다.
- **CI 러너 이름**: `.github/workflows/test.yml`의 `macos-26`은 푸시해 보지 못해 확인하지 못했습니다(위 11번 결과).

10번 항목을 하다가 (2026-11-11):

- **1배율에서 바탕이 캐시에 들어감**: GPU로 굽는 기준(`ShapeBaker.largeTexturePixels`, 100만 픽셀)이 배율을 곱한 픽셀이라, 2배율 사무실 창의 바탕(약 350만 픽셀)은 GPU로 굽고 캐시하지 않지만 1배율(약 88만 픽셀)은 CPU로 굽고 캐시에 담깁니다(3.4MB, 가구를 다시 만들 때마다 한 장씩). 새 캐시 상한(32MiB) 안이라 커지지는 않지만, 바탕은 배율과 상관없이 캐시하지 않는 쪽이 맞을 수 있습니다. 2단계 실측과 함께 보면 됩니다.
- **`perf-window.sh open`이 Esc를 맨 앞 앱에 보냄**: 메뉴를 닫으려고 `key code 53`을 System Events로 보내 그때 앞에 있는 다른 앱(터미널 등)이 받을 수 있습니다. `PERF_PID`를 줘도 같습니다(이번에 고치지 않음).
- **`ShapeBaker`의 전역 상태가 늘었음**: 11번 동시성 조사에서 경고 원인으로 꼽힌 전역 캐시에 이번에 `scalesInUse`·`ledger`가 더해졌습니다. Swift 6 전환 때 `ShapeBaker`에 `@MainActor`를 다는 것(장면·노드와 함께)으로 한꺼번에 정리하면 됩니다.
- **장면 등록을 풀지 않음**: `ShapeBaker.use(scales:by:)`는 장면을 `ObjectIdentifier`로 기억하고 풀지 않습니다. 지금 장면 둘(사무실·미니)은 앱이 끝날 때까지 살아 있어 문제없지만, 장면을 새로 만들고 버리게 되면 `deinit`에서 풀어야 합니다.
- **사무실 창을 열 때 임시 크기로 한 번 더 구움** (2단계 실측): 계측에 `1127x1127@2.0x` 크기의 바탕이 남습니다. 창이 만들어지는 동안 장면이 정사각형에 가까운 임시 크기를 거치며 바탕을 한 번 굽고, 곧 실제 크기(1182×751)로 다시 굽는 것으로 보입니다(지금은 굽는 데 수십 ms, 캐시하지 않아 메모리는 남지 않음). 크기가 자리 잡은 뒤에만 굽게 하면 창을 열 때 한 번을 아낄 수 있습니다. (`OfficeScene.sync`, `didChangeSize`)
- **측정 실행도 사무실 창 위치를 저장함**: SwiftUI가 `NSWindow Frame office`를 스스로 저장해, 같은 번들 ID로 나란히 띄운 측정 앱이 설치된 앱의 창 위치를 덮어썼습니다(2단계 결과). 측정 때 창 자동 저장을 끄거나 1단계의 `side-prepare`(번들 ID를 나눈 복사본)로 띄우면 피할 수 있습니다.

화면 점검에서 나온 것 (2026-11-16) — 셋은 같은 날 고침:

- **고침 — 사무실 창을 닫아도 그래픽 메모리가 돌아오지 않음**: SwiftUI가 닫은 창과 그 안의 `SKView`·패널을 그대로 들고 있었습니다. 이제 창이 닫혀 있는 동안에는 내용을 내려놓고(`OfficeWindowView.presented` — `WindowAccessor`가 창의 닫힘(`willClose`)·다시 보임(occlusion·key·deminiaturize)을 알림, 최소화는 내려놓지 않음), 장면이 뷰에서 떨어질 때 가구 텍스처와 텍스처 캐시를 바로 놓습니다(`OfficeScene.willMove(from:)`, `ShapeBaker.purge`). 번들 ID를 나눈 복사본을 따로 띄워 화면이 켜진 채로 잰 값(`footprint`, 미니 켬, 직원 26명):

  | 상태 | 고치기 전 | 고친 뒤 |
  |---|---|---|
  | 미니만 (사무실 창을 열기 전) | 86MB | 86MB |
  | 사무실 창 보임 60초 | 244MB | 237MB |
  | 닫고 90초 (미니 복귀) | 214MB | **161MB** |
  | 다시 열고 30초 | 237MB | 242MB |
  | 다시 닫고 60초 | 208MB | **155MB** |

  닫은 뒤 줄어든 몫은 창 백버퍼(IOSurface 38 → 3MB), 그림판(unmapped graphics 73 → 55MB), 텍스처(IOAccelerator 20 → 10MB)입니다. 다시 열면 장면·패널·밤 조명까지 정상으로 그려지는 것을 캡처로 확인했습니다. 열기 전(86MB)까지 돌아오지 않는 몫은 힙(MALLOC_SMALL +18MB)과 CoreAnimation 14MB입니다.
  - **남은 것 — 보이는 상태 237~244MB는 그대로**(2배율 목표 200MB 초과). 나눠 보면 미니만일 때보다 unmapped graphics +23MB(그림판 2장), IOSurface +35MB(창 백버퍼), IOAccelerator +27MB(텍스처), `CG image` +27MB, 힙 +18MB, CoreAnimation +15MB입니다. 줄일 수 있는 후보: (1) `SKTexture(cgImage:)`가 들고 있는 CPU 사본 27MB — 큰 층의 비트맵을 파일에 매핑한 메모리로 만들면 footprint에서 빠지지만 굽을 때마다 파일 쓰기가 생김, (2) 그림판 배율(`CLAUDE_OFFICE_DRAWABLE_SCALE` 실험, 글자까지 흐려짐). 둘 다 화질·끊김을 화면에서 견줘야 해서 하지 않았습니다. 목표를 "보이는 상태 250MB"로 고치는 쪽도 선택지입니다.
  - 미니만 있어도 그리는 뷰가 하나 있으면 unmapped graphics 약 50MB가 잡힙니다(10번의 31MB는 화면이 잠겨 그리지 않은 값). SpriteKit·Metal 바탕 몫으로 보이며 손대지 않았습니다.
- **고침 — 메뉴바 경고 느낌표가 메뉴를 열 때까지 낡은 채로 남음**: 5초마다 도는 디렉토리 새로 고침에서 30초에 한 번 settings.json·훅 스크립트·차단 설정을 다시 읽습니다(`AppModel.refreshHookFilesIfStale`, 바뀐 값만 넣음, `claude --version`은 부르지 않음). 화면 확인 필요: `~/.claude`를 건드리지 않으려고 낡은 상태를 일부러 만들어 보지는 않았습니다.
- **고침 — 이벤트 로그 창이 가장 오래된 줄에서 열림**: 열 때 맨 아래로 내립니다(`EventLogView`). 따로 띄운 복사본에 훅 81개를 보낸 뒤 열어 마지막 줄이 보이는 것을 캡처로 확인했습니다.
- **가려진 사무실 창은 마지막 장면에서 멈춤**: 다른 창에 완전히 가려지면 장면이 멈추므로(의도한 동작) 창 미리 보기·캡처에는 멈춘 순간의 모습(예: 하품하는 직원)이 남습니다. 문제는 아니고 점검할 때 알아 둘 점입니다.
- **덤으로 본 것 — 밤 장면**: 따로 띄운 복사본이 밤 조명이어서, 다시 연 사무실 창에서 스탠드·책상 불빛과 따뜻한 흰색 ♪·Zz가 어두운 바탕 위에서 읽히는 것을 캡처로 봤습니다(8번의 밤 항목). 소파 스탠드 불빛 바로 위의 ♪는 그 자리에 사람이 없어 보지 못했습니다.
