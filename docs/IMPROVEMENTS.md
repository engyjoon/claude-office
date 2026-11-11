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
| 6 | 조용한 실패 없애기·첫 실행 안내 | Opus 5.5 (medium) | 대기 | |
| 7 | 훅 서버·설정 파일 안전 (+ 죽은 터미널 세션 퇴근) | Sonnet 5.5 (medium) | 대기 | |
| 8 | 화면 디자인 다듬기 | Opus 5.5 (high) | 대기 | |
| 9 | 문구·경과 시간·잔손질 | Sonnet 5.5 (medium) | 대기 | |
| 10 | 레티나 메모리 줄이기 | Opus 5.5 (high) | 대기 | |
| 11 | 구조 정리와 안전망 | Fable 5.2 (high) | 대기 | |

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

**결과**:

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

**결과**:

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

**결과**:

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

**결과**:

## 10. 레티나 메모리 줄이기

**문제 (실측)**: 5K 2배율 화면에서 실행 3시간 41분 뒤 `footprint`가 326MB입니다(목표는 1배율 150MB). 그래픽이 약 240MB입니다(unmapped graphics 146MB, IOAccelerator 77MB, IOSurface 20MB). 설계서 §8.3이 "레티나면 넘을 가능성이 큼"이라며 측정을 미뤄 둔 부분입니다.

- 캐릭터·말풍선은 텍스처 배율이 바뀌어도 다시 굽지 않습니다. 1배율 화면에서 켠 뒤 레티나가 붙으면 흐리고, 반대면 4배 텍스처를 계속 듭니다. (`App/Sources/ShapeBaker.swift:27-33`, `App/Sources/OfficeScene.swift:350-354`, `:704-752`)
- 텍스처 캐시는 300장에서 통째로 비웁니다. (`ShapeBaker.swift:49`, `:156`)
- `AVAudioEngine`을 소리 묶음마다 메인 스레드에서 시작합니다(전제 미확인: 끊김). (`App/Sources/SoundPlayer.swift:85-118`)

**고칠 방향**: 먼저 `make perf`와 `footprint`로 상황별(메뉴바만·미니·사무실 창) 메모리를 재서 어디가 큰지 나눕니다. 그다음 바닥·벽 같은 큰 층을 1배율로 굽기, 그림판 크기, 배율이 바뀔 때 캐릭터 다시 굽기, 캐시를 오래된 것부터 비우기를 차례로 재며 적용합니다. 목표를 "1배율 150MB / 2배율 ○○MB"로 나눠 설계서에 적습니다.

**주의**: 측정에는 앱 실행이 필요합니다. 설치된 앱을 바꾸지 않고 `scripts/perf-launch.sh isolated`의 격리 실행을 쓰되, 실행 중인 앱과 충돌하면(엔드포인트 파일, 7번 항목) 멈추고 사용자에게 묻습니다.

**완료 기준**: 고치기 전후 측정값이 `build/perf/results.md`와 이 문서에 있습니다.

**결과**:

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

**결과**:

---

## 새로 발견한 것

(항목을 진행하다 범위 밖에서 발견한 문제를 여기에 적습니다.)

4번 항목을 하다가 (2026-11-11):

- **`PostToolBatch` 훅** (2.1.321 실행 파일에 있음: "한 묶음의 도구가 모두 끝난 뒤, 다음 모델 요청 전에 한 번"). 설치 목록에 넣고 파서가 받으면 도구 묶음의 경계를 정확히 알 수 있어 4번의 "2초 간격" 추정을 대신할 수 있습니다. 설치 목록·버전 조건은 1·7번 범위입니다. (`Sources/OfficeCore/Hooks/HookSettingsEditor.swift`, `HookParser.swift`)
- **기본 9종만 설치돼 있으면 실패한 도구에 끝 이벤트가 없습니다** (`PostToolUse`는 성공만). 1번의 "다시 설치"로 `PostToolUseFailure`가 들어가기 전까지 이 맥에서는 오류 연출(💦)이 나오지 않고 4번의 묶음 규칙이 뒷정리만 합니다.
- **파서가 버리는 알림 종류**: 2.1.321의 `notification_type`에 `worker_permission_prompt`·`agent_needs_input`·`agent_completed`가 있습니다. 서브·워커의 승인 요청이 `worker_permission_prompt`로 올 수 있다면 지금은 무시됩니다. 실제 페이로드를 수집해 봐야 합니다. (`HookParser.swift:114-129`)
- **tick에서만 바뀐 상태가 앱에 늦게 보임**: `AppModel.frame()`은 `engine.tick`의 지시만 무대에 넘기고 명단·현황 줄·알림은 고치지 않아, 압축 시간 초과·출근 중 → 쉬는 중·1시간 규칙이 다음 훅이나 5초마다 도는 `syncResidents` 때 반영됩니다. 11번의 `commit(_:at:)` 통합에서 tick 경로도 같이 태우면 됩니다. (`App/Sources/AppModel.swift:316`, `:502`)
- **시나리오가 실제와 다른 곳**: `Scenarios/mini.jsonl` 14.2초의 `Notification`에 `agent_id`가 실려 있지만 실제 알림에는 없습니다(4번 전제 확인). 지금 동작에는 영향이 없습니다.
- **죽은 터미널 세션이 자리에 남음**: PID 확인 방식으로 7번 항목에 넣었습니다 (사용자 결정).
