# Claude Office 설계서 (v0.2)

> Claude Code 에이전트들이 일하는 모습을 보여주는 macOS 네이티브 가상 사무실 앱
>
> - 앱 이름: **Claude Office** (번들 ID `com.engyjoon.claudeoffice`)
> - 문서 상태: v0.3. **M1(코어) 구현 완료** — 구현하면서 바뀐 점은 §6.4에 정리했습니다. v0.2에서 바뀐 점: 앱 이름, 효과음(§11), 미니 사무실 크기 조절(§10.1), Claude Code 2.1.318 훅 확인 결과(§4)
> - 스타일 미리보기: [`docs/preview/index.html`](preview/index.html)
> - 훅 수집 안내: [`docs/M0-capture.md`](M0-capture.md)

---

## 1. 개요

### 1.1 목표

- 개발 노트북에서 코딩하는 동안 **Claude Code 세션과 서브에이전트의 상태를 한눈에** 볼 수 있게 합니다.
- 상태를 숫자나 로그가 아니라 **아기자기한 캐릭터가 일하는 사무실**로 보여줍니다. 캐릭터는 말풍선으로 대화하고, 표정과 제스처로 감정을 표현합니다.
- 실제로 쓸모 있는 신호를 놓치지 않게 합니다. 특히 **권한 승인 대기**는 즉시 눈에 띄어야 합니다.
- 하루 종일 띄워둬도 부담이 없어야 합니다 (저전력, 포커스를 빼앗지 않음).

### 1.2 비목표 (MVP 범위 밖)

- 앱에서 에이전트에게 지시하거나 권한을 승인·거부하는 기능 (v2 검토)
- 여러 사람이 함께 쓰는 팀 공유 사무실 (v2 이후)
- Windows, Linux 지원
- App Store 배포 (샌드박스 제약, §12 참고)

### 1.3 확정된 결정 사항

| # | 항목 | 결정 |
|---|---|---|
| ① | 캐릭터 단위 | 세션 = **팀장**, 서브에이전트 = **팀원**. `.claude/agents/*.md`로 정의한 에이전트는 **고정 직원**(항상 같은 얼굴, 이름, 자리) |
| ② | 사무실 구성 | 한 사무실 안에 **프로젝트(cwd)별 팀 구역** |
| ③ | 상호작용 | 보기 + 알림 + 클릭하면 상세 정보 / 터미널로 이동 |
| ④ | 공개 범위 | 본인용으로 시작하되 오픈소스 공개를 염두에 둡니다. **그래픽과 효과음은 모두 직접 제작**한 에셋만 사용합니다 |
| ⑤ | 앱 이름 | **Claude Office** |
| ⑥ | 캐릭터 말투 | 모든 캐릭터가 밝고 정중한 **해요체**로 통일 |
| ⑦ | 효과음 | 작고 아기자기한 합성음. **종류별로 켜고 끌 수 있음** (§11) |
| ⑧ | 미니 사무실 | 기본 위치는 화면 **오른쪽 아래**, 크기는 **자유롭게 조절** (§10.1) |
| 기술 | 기본값 | macOS 14+, SwiftUI + AppKit + SpriteKit, `127.0.0.1` HTTP 수신, 훅 우선(JSONL은 2단계), SwiftPM 코어 + XcodeGen, 소스 빌드 배포 |

---

## 2. 사용 시나리오

1. **아침 출근:** 터미널에서 `claude`를 실행하면 사무실 문이 열리고 팀장 캐릭터가 들어와 해당 프로젝트 책상에 앉습니다.
2. **업무 지시:** 프롬프트를 입력하면 종이비행기가 날아와 팀장에게 도착하고, 팀장 머리 위에 💡가 뜹니다.
3. **위임:** 팀장이 서브에이전트(`code-reviewer`)를 호출하면 고정 직원 "코드리뷰어"가 문으로 들어옵니다. 팀장 자리로 걸어와 대화한 뒤(팀장: "RouterConfig 리뷰 부탁해요!" / 팀원: "맡겨주세요!") 자기 자리에 앉습니다.
4. **작업 중:** 파일을 읽으면 자료를 넘기고, 편집하면 타이핑하고, 오래 걸리는 명령을 실행하면 서버랙으로 가서 작업합니다.
5. **승인 대기:** 권한 요청이 생기면 캐릭터가 일어나 손을 들고 ❗ 말풍선("`npm test` 실행해도 될까요?")을 띄웁니다. 메뉴바 아이콘에 배지가 붙고 macOS 알림이 옵니다. 알림을 클릭하면 해당 터미널이 앞으로 나옵니다.
6. **완료 보고:** 서브에이전트가 끝나면 팀장에게 걸어와 하이파이브를 하고("다 했어요!") 퇴근합니다. 팀장이 응답을 마치면 기지개를 켭니다.
7. **휴식:** 오래 대기 상태가 이어지면 휴게실에서 커피를 마시고, 더 길어지면 책상에서 꾸벅꾸벅 좁니다(💤).
8. **퇴근:** 세션이 끝나면 손을 흔들고 문으로 나갑니다.

---

## 3. 시스템 아키텍처

```
┌──────────────── Claude Code (여러 세션) ────────────────┐
│  hooks: SessionStart / UserPromptSubmit / PreToolUse /    │
│         PostToolUse / Notification / Stop / Subagent* …   │
└───────────────┬───────────────────────────────────────────┘
                │ stdin JSON → claude-office.sh → curl (비동기, 1초 타임아웃)
                ▼
┌──────────────────────── Claude Office.app ─────────────────────────┐
│ [HookServer]  127.0.0.1:47821  POST /v1/hook  (토큰 검증)          │
│      │                                                            │
│      ▼                                                            │
│ [OfficeCore]  ← 순수 Swift, Linux에서도 빌드·테스트 가능            │
│   HookParser → OfficeEvent → OfficeReducer → OfficeState          │
│                                  │                                │
│                           Choreographer (연출 결정, 시간 주입)      │
│                                  │  [Directive]                   │
│      ┌───────────────────────────┼───────────────────────┐        │
│      ▼                           ▼                       ▼        │
│ [OfficeScene: SpriteKit]   [SwiftUI: 메뉴바·인스펙터]  [Notifier]    │
│  캐릭터 리그, 말풍선, 길찾기   상태 목록, 설정, 훅 설치   UNUserNotif.  │
└───────────────────────────────────────────────────────────────────┘
```

**설계 원칙**

- **판단은 코어, 연출은 씬.** "무엇을 보여줄지"는 모두 `OfficeCore`의 순수 함수가 결정하고, 결과를 `Directive` 목록으로 내보냅니다. SpriteKit 씬은 받은 지시를 그대로 그리기만 합니다. 이렇게 나누면 핵심 로직을 리눅스 클라우드 세션에서도 테스트할 수 있습니다.
- **Claude Code를 절대 방해하지 않습니다.** 훅 스크립트는 항상 즉시 `exit 0`하고, 아무것도 출력하지 않으며, 앱이 꺼져 있어도 조용히 넘어갑니다.
- **모르는 이벤트는 무시합니다.** Claude Code 버전에 따라 훅 필드가 달라질 수 있으므로, 파서는 관대하게 만들고 알 수 없는 필드와 이벤트는 버립니다.

---

## 4. 이벤트 수집

### 4.1 구독할 훅 이벤트

| 훅 이벤트 | 주요 필드 (공통: `session_id`, `cwd`, `transcript_path`, `hook_event_name`) | 용도 |
|---|---|---|
| `SessionStart` | `source` (startup / resume / clear / compact) | 팀장 출근, 팀 구역 배정 |
| `SessionEnd` | `reason` | 팀장 퇴근 |
| `UserPromptSubmit` | `prompt` | 새 업무 도착 연출 (프롬프트 내용은 기본적으로 표시하지 않음) |
| `PreToolUse` | `tool_name`, `tool_input`, `tool_use_id` | 활동 시작. `Agent` 툴(구버전 이름 `Task`)이면 서브에이전트 위임 |
| `PostToolUse` | `tool_name`, `tool_response`, `tool_use_id` | 활동 종료 (성공) |
| `PostToolUseFailure` (지원 버전만) | `tool_name`, 오류 정보 | 툴 오류 연출. 없으면 `tool_response`로 판단 |
| `Notification` | `message`, (버전에 따라) `notification_type` | 권한 승인 대기, 입력 대기 |
| `PermissionRequest` (지원 버전만) | `tool_name`, `tool_input` | 권한 대기를 더 정확하게 감지 (관찰만 하고 결정은 돌려주지 않음) |
| `Stop` | `stop_hook_active` | 팀장 응답 완료 |
| `SubagentStart` (지원 버전만) | `agent_id`, `agent_type` | 팀원 출근 (정확한 식별) |
| `SubagentStop` | `agent_id`, `agent_type`, `agent_transcript_path`, `last_assistant_message` | 팀원 작업 완료 → 보고 후 퇴근 |
| `PreCompact` | `trigger` | "서류 정리 중" 연출 |

> **Claude Code 2.1.318에서 확인한 사실** (실행 파일의 훅 스키마 기준)
> - `SubagentStart`, `PermissionRequest`, `PostToolUseFailure`, `PermissionDenied`, `StopFailure` 등 이벤트가 있습니다.
> - 서브에이전트 안에서 발생한 훅에는 **`agent_id`와 `agent_type`이 붙습니다.** 메인 스레드에서는 `agent_id`가 없습니다.
> - `Notification.notification_type`에는 `permission_prompt`, `idle_prompt` 등이 들어옵니다.
>
> **M0 실제 수집 결과** (2026-11, Claude Code 2.1.318, macOS, 98건, iTerm.app·vscode)
> - 위 필드 구성이 실제와 일치했습니다. 서브에이전트 안의 툴 이벤트에는 `agent_id`·`agent_type`이 붙어 옵니다.
> - 처음 보는 공통 필드: `scratchpad_dir`, `effort.level`, Stop/SubagentStop의 `session_crons` (사용하지 않음, 무시).
> - 처음 보는 툴 `SubagentHandback`(입력: `message`): 서브에이전트가 결과를 넘기는 동작으로 보고 "보고 정리 중" 연출(서류 정리 자세)로 처리합니다. 메시지 내용은 표시하지 않습니다.
> - **서브에이전트 유형 3가지** (`capture.py breakdown`으로 확인):
>   1. **일반 위임** (`general-purpose` 등): `Agent` 위임 → `SubagentStart` → 툴 이벤트(`agent_id` 포함) → `SubagentHandback` → `SubagentStop` → `PostToolUse(Agent)`.
>   2. **신호 없는 위임** (`web-fetch`): `Agent` 위임 → 툴 이벤트만 오고 `SubagentStart`/`SubagentStop`이 없습니다 → `PostToolUse(Agent)`로 끝납니다.
>   3. **Claude Code 내부 작업**: `agent_type`이 빈 `SubagentStop` 하나만 옵니다 (16건 중 14건). 다른 이벤트가 없고 사용자가 맡긴 일이 아니므로 **무시**합니다.
> - 그래서 팀원 종료 규칙을 이렇게 정했습니다: `SubagentStart`를 받은 팀원과 백그라운드 위임은 `SubagentStop`으로, 그 밖에는 `PostToolUse(Agent)`로 끝냅니다. 종류가 빈 신호는 무시합니다. 안전장치로, 팀장의 응답이 끝날 때(`Stop`) 남은 포그라운드 팀원은 보고하고 퇴근합니다.
> - 메인의 `Bash` 하나가 끝나지 않은 채 남은 경우가 있었습니다 (중단 추정). 팀장의 `Stop`/새 프롬프트에서 진행 중인 툴을 비우므로 화면에 남지 않습니다.
> - `TERM_PROGRAM`: iTerm2는 `iTerm.app`, VS Code 터미널은 `vscode`.
> - `idle_prompt` 알림은 이번 수집에 없었습니다 (파서는 처리함).
>
> ⚠️ **M0에서 반드시 확인할 것:** 필드 구성은 Claude Code 버전마다 다를 수 있습니다. 구현 전에 사용 중인 버전에서 실제 페이로드를 수집해 테스트 픽스처로 저장하고([M0 안내](M0-capture.md)), 파서는 그 픽스처를 기준으로 만듭니다.

### 4.2 훅 스크립트

`~/.claude/hooks/claude-office.sh`에 설치합니다.

```sh
#!/bin/sh
# Claude Office 훅: 어떤 경우에도 Claude Code를 막지 않습니다.
# - 아무것도 출력하지 않습니다 (SessionStart/UserPromptSubmit의 stdout은 컨텍스트에 추가되기 때문)
# - 앱이 꺼져 있거나 응답이 없어도 즉시 종료합니다
ENDPOINT_FILE="$HOME/Library/Application Support/ClaudeOffice/endpoint"
[ -r "$ENDPOINT_FILE" ] || { cat >/dev/null; exit 0; }
read -r PORT TOKEN < "$ENDPOINT_FILE"
payload=$(cat)
( printf '%s' "$payload" | curl -s -m 1 -X POST \
    -H "Content-Type: application/json" \
    -H "X-Office-Token: $TOKEN" \
    -H "X-Office-Term: ${TERM_PROGRAM:-unknown}" \
    --data-binary @- "http://127.0.0.1:$PORT/v1/hook" >/dev/null 2>&1 & )
exit 0
```

- `X-Office-Term`으로 iTerm2, Apple Terminal, VS Code, Ghostty 등을 구분합니다. "터미널로 이동" 기능에 씁니다.
- `endpoint` 파일에는 앱이 실행될 때마다 `포트 토큰`을 기록합니다. 기본 포트는 47821이며, 사용 중이면 다른 포트를 고르고 파일을 갱신합니다.

### 4.3 settings.json 훅 등록 (앱의 "훅 설치" 버튼이 자동으로 처리)

```json
{
  "hooks": {
    "SessionStart":     [{ "hooks": [{ "type": "command", "command": "~/.claude/hooks/claude-office.sh" }] }],
    "SessionEnd":       [{ "hooks": [{ "type": "command", "command": "~/.claude/hooks/claude-office.sh" }] }],
    "UserPromptSubmit": [{ "hooks": [{ "type": "command", "command": "~/.claude/hooks/claude-office.sh" }] }],
    "PreToolUse":       [{ "matcher": "*", "hooks": [{ "type": "command", "command": "~/.claude/hooks/claude-office.sh" }] }],
    "PostToolUse":      [{ "matcher": "*", "hooks": [{ "type": "command", "command": "~/.claude/hooks/claude-office.sh" }] }],
    "Notification":     [{ "hooks": [{ "type": "command", "command": "~/.claude/hooks/claude-office.sh" }] }],
    "Stop":             [{ "hooks": [{ "type": "command", "command": "~/.claude/hooks/claude-office.sh" }] }],
    "SubagentStop":     [{ "hooks": [{ "type": "command", "command": "~/.claude/hooks/claude-office.sh" }] }],
    "PreCompact":       [{ "hooks": [{ "type": "command", "command": "~/.claude/hooks/claude-office.sh" }] }]
  }
}
```

설치기는 `claude --version`을 확인해서 2.1.318 이상이면 `SubagentStart`, `PermissionRequest`, `PermissionDenied`, `PostToolUseFailure`, `StopFailure`를 함께 등록합니다. 그보다 낮으면 위 기본 이벤트만 등록합니다. 지원하지 않는 이벤트 이름이 설정 검증 오류를 일으킬 수 있기 때문입니다.

**설치기 동작 규칙**

1. `~/.claude/settings.json`을 `settings.json.bak-YYYYMMDD-HHMMSS`로 백업합니다.
2. 기존 훅은 그대로 두고, 우리 항목만 추가합니다. 우리 항목은 명령 경로(`claude-office.sh`)로 구분합니다.
3. 여러 번 실행해도 결과가 같아야 합니다(멱등성).
4. 제거는 우리 항목만 지웁니다.
5. 프로젝트별 `.claude/settings.json`과 관리형(managed) 설정은 건드리지 않습니다.

### 4.4 서브에이전트 식별

| 상황 | 처리 |
|---|---|
| 페이로드에 `agent_id` / `agent_type`이 있음 (2.1.318 확인) | 그대로 사용합니다. 툴 이벤트에 `agent_id`가 있으면 그 팀원의 활동, 없으면 팀장의 활동입니다 |
| `PreToolUse(Task/Agent)`만 있음 | `tool_input.subagent_type`, `description`으로 팀원을 만들고, `tool_use_id`로 시작과 종료를 짝짓습니다 |
| (구버전 대비) `agent_id`가 없어 누가 했는지 알 수 없음 | 그 세션에 활성 팀원이 한 명이면 그 팀원에게, 여러 명이면 "팀 공용 활동"으로 처리합니다 (팀 구역에 아이콘만 표시) |

툴 이름은 버전에 따라 `Task` 또는 `Agent`일 수 있으므로 둘 다 처리합니다.

### 4.5 고정 직원 프로필 수집

- `~/.claude/agents/*.md`와 각 팀 `cwd`의 `.claude/agents/*.md`를 읽어 frontmatter의 `name`, `description`을 가져옵니다.
- `name`이 고정 직원의 키가 됩니다. 외형은 이름 해시로 결정해서 항상 같게 유지하고, 사용자가 앱에서 바꿀 수 있습니다(§9.4).
- `general-purpose`처럼 기본 제공되는 서브에이전트는 **임시 직원**으로 처리합니다. 출근할 때마다 외형이 바뀌고, 머리에 새싹 🌱 액세서리를 답니다.

---

## 5. 도메인 모델 (OfficeCore)

```swift
// 정규화된 이벤트 (HookParser의 출력)
public enum OfficeEvent: Equatable, Sendable {
    case sessionStarted(SessionRef, cwd: String, term: String?)
    case sessionEnded(SessionRef)
    case promptSubmitted(SessionRef)
    case toolStarted(ActorRef, ToolCall)
    case toolFinished(ActorRef, ToolCall, outcome: ToolOutcome)
    case subagentSpawned(parent: SessionRef, member: MemberRef, task: String?)
    case subagentFinished(MemberRef)
    case permissionRequested(ActorRef, summary: String?)
    case waitingForInput(SessionRef)
    case turnEnded(SessionRef)
    case compacting(SessionRef)
}

public struct ToolCall: Equatable, Sendable {
    public var id: String?           // tool_use_id
    public var name: String          // "Read", "Edit", "Bash", "mcp__x__y" …
    public var category: ToolCategory
    public var subject: String?      // 파일명, 명령어 앞부분, 검색어 등 (표시용으로 요약됨)
}

public enum ToolCategory: Sendable {
    case read        // Read, Grep, Glob, LS, NotebookRead
    case write       // Edit, Write, MultiEdit, NotebookEdit
    case shell       // Bash, BashOutput
    case web         // WebSearch, WebFetch
    case plan        // TodoWrite, ExitPlanMode
    case delegate    // Task, Agent
    case mcp         // mcp__*
    case other
}

public struct Agent: Identifiable, Sendable {
    public let id: AgentID
    public var role: Role                // .lead / .member
    public var profile: AgentProfile     // 이름, 외형, 고정 여부
    public var teamID: TeamID
    public var activity: Activity
    public var mood: Mood                // 표정 선택에 영향 (연속 오류 → 곤란 등)
    public var activitySince: Date
}

public enum Activity: Equatable, Sendable {
    case arriving, idle, thinking
    case reading(String?), writing(String?), running(String?), browsing(String?)
    case planning, delegating(to: AgentID), reporting(to: AgentID)
    case waitingForPermission(String?), waitingForInput
    case celebrating, troubled, compacting, onBreak, napping, leaving
}

public struct Team: Identifiable, Sendable {
    public let id: TeamID          // cwd 경로 해시
    public var name: String        // 폴더 이름 (예: "a-sdn-portal")
    public var leadIDs: [AgentID]  // 같은 프로젝트에서 세션 여러 개 가능
    public var memberIDs: [AgentID]
    public var deskIsland: Int     // 사무실의 책상 섬 슬롯 번호
    public var color: TeamColor    // 러그·명패 색
}
```

- `OfficeReducer.apply(_ event: OfficeEvent, at: Date, state: inout OfficeState) -> [Directive]`: 상태를 바꾸고 연출 지시를 돌려주는 **순수 함수**입니다.
- 시간은 `Clock` 프로토콜로 주입합니다. 테스트에서는 가짜 시계로 "3초 경과"를 재현합니다.
- 같은 프로젝트에서 세션을 여러 개 열면 같은 팀에 팀장이 여러 명 생깁니다(공동 팀장석).

---

## 6. 연출 엔진 (Choreographer)

### 6.1 연출 지시 (Directive)

```swift
public enum Directive: Equatable, Sendable {
    case spawn(AgentID, at: Spot)                     // 문 앞에 등장
    case walk(AgentID, to: Spot)                      // 길찾기 이동
    case sit(AgentID), stand(AgentID)
    case pose(AgentID, Pose)                          // 지속 동작: typing, reading, holdingCup …
    case gesture(AgentID, Gesture)                    // 1회성 동작: wave, nod, thumbsUp …
    case express(AgentID, Expression, for: Duration?) // 표정
    case emote(AgentID, Emote)                        // 머리 위 아이콘: ❗ ❓ 💡 💦 ✨ 💤 ♪
    case say(AgentID, Bubble)                         // 말풍선
    case status(AgentID, StatusPill?)                 // 머리 위 상태 칩 ("Edit · RouterConfig.java")
    case prop(AgentID, Prop?)                         // 들고 있는 소품: 책, 서류, 커피, 노트북
    case effect(Effect)                               // 종이비행기, 하이파이브 반짝임 등
    case sound(SoundCue)                              // 효과음 (§11). 재생 여부는 SoundPlayer가 설정을 보고 결정
    case despawn(AgentID)
}
```

### 6.2 이벤트 → 연출 매핑

| 이벤트 / 상태 | 위치 | 자세·제스처 | 표정 | 말풍선·아이콘 |
|---|---|---|---|---|
| 세션 시작 | 문 → 팀장석 | 걷기 → 앉기, 손 흔들기 | 기본 | "좋은 아침이에요!" |
| 프롬프트 입력 | 팀장석 | 종이비행기 받기 | 놀람 → 기쁨 | 💡 |
| 생각 중 (프롬프트 후 첫 툴 전) | 자리 | 턱 괴기 | 생각 | 생각 풍선 "음…" |
| read (Read/Grep/Glob) | 자리. 연속 5회 이상이면 **책장** | 서류 넘기기 | 집중 | 상태 칩 "Read · auth.ts" |
| write (Edit/Write) | 자리 | 타이핑 | 집중 | 상태 칩 "Edit · RouterConfig.java" |
| shell (Bash) 2초 이내 | 자리 | 타이핑 (모니터 초록 빛) | 집중 | 상태 칩 "Bash · git status" |
| shell 2초 초과 | **서버랙** | 서버 만지기, 기다리며 발 까딱 | 기본 | 생각 풍선 "빌드 기다리는 중…" |
| web (WebSearch/WebFetch) | **창가 리서치 코너** (지구본) | 지구본 돌리기 / 책 읽기 | 호기심 | "SpriteKit 문서 찾는 중" |
| plan (TodoWrite) | **화이트보드** | 마커로 쓰기 | 집중 | "할 일 정리!" |
| delegate (Task/Agent) | 팀장석 | 일어나서 손짓 | 기쁨 | 팀장 "○○ 부탁해요!" (§7.3 대화 스크립트) |
| 팀원 출근 | 문 → 팀장석 → 팀원석 | 걷기, 고개 끄덕 | 의욕 | 팀원 "맡겨주세요!" |
| **권한 승인 대기** | 자리 | **일어나서 손 들기** (반복) | 간절 | 외침 풍선 "`npm test` 실행해도 될까요?" + ❗ |
| 툴 오류 | 자리 | 머리 긁적 | 곤란 | 💦 "어라…?" |
| 연속 오류 3회 이상 | 자리 | 머리 감싸기 | 슬픔 | 💦 "으으…" (mood = troubled) |
| 서브에이전트 완료 | 팀원석 → 팀장석 | 하이파이브 | 뿌듯 | 팀원 "다 했어요!" / 팀장 "고마워요!" ✨ |
| 팀원 퇴근 | 팀장석 → 문 | 손 흔들기 | 기쁨 | (고정 직원은 자리에 이름표가 남음) |
| 응답 완료 (Stop) | 자리 | 기지개 | 뿌듯 | ✨ "끝!" |
| 입력 대기 60초 이상 | **휴게실** | 커피 마시기 | 편안 | ♪ |
| 입력 대기 10분 이상 | 자리 | 꾸벅꾸벅 | 졸림 | 💤 |
| 컨텍스트 정리 (PreCompact) | 자리 | 서류 정리 | 집중 | "서류 정리 중…" |
| 세션 종료 | 자리 → 문 | 손 흔들기 | 기쁨 | "수고하셨습니다!" |

### 6.3 깜빡임 방지 규칙 (가장 중요한 튜닝 포인트)

툴 호출은 수십 밀리초 단위로 연달아 일어나기 때문에, 그대로 그리면 캐릭터가 정신없이 움직입니다.

1. **최소 유지 시간:** 한 활동은 최소 2.5초 유지합니다. 그 사이 들어온 이벤트는 카테고리별로 최신 것만 남기고 합칩니다.
2. **이동 문턱:** 자리를 떠나는 이동은 "그 활동이 계속될 것"이라는 근거가 있을 때만 합니다.
   - read: 10초 안에 5회 이상
   - shell: `PostToolUse`가 2초 안에 오지 않음
   - web, plan: 즉시 이동 (보통 오래 걸리기 때문)
3. **우선순위:** 권한 대기 > 오류 > 위임·보고 대화 > 일반 활동 > 잡담. 높은 우선순위가 오면 이동 중이어도 즉시 반영합니다.
4. **이동 취소:** 목적지에 도착하기 전에 활동이 끝나면 그 자리에서 돌아섭니다.
5. **동시 이동 제한:** 한 팀에서 동시에 걷는 캐릭터는 최대 2명입니다.

### 6.4 M1 구현 메모 (설계에서 구체화하거나 바뀐 점)

- **두 단계 구조:** `OfficeState`(리듀서)가 이벤트를 받아 의미 단위의 `Beat`(출근, 위임, 보고, 승인 요청 …)를 내고, `Choreographer`가 `Beat`를 `Directive`로 바꿉니다. 앱은 `OfficeEngine` 하나만 들고 `handle(hookPayload:)`와 `tick(at:)`(0.25초 주기)만 부르면 됩니다.
- **직원별 대기열:** 씬은 직원마다 지시를 순서대로 실행합니다. `walk`와 `wait`는 다음 지시를 막고, 두 직원의 타이밍은 `signal`/`await`로 맞춥니다 (보고하러 온 팀원이 도착한 뒤 팀장이 하이파이브). 승인 요청·보고·퇴근처럼 급한 연출은 `clearQueue`로 시작합니다. `agent`가 없는 지시(팀 열기, 종이비행기, 알림성 효과음)는 바로 실행합니다.
- **유지 시간의 예외:** 더 바쁜 활동으로 바뀔 때(대기 → 생각 → 작업)는 2.5초를 기다리지 않고 바로 보여줍니다. 같은 등급끼리나 덜 바쁜 쪽으로 바뀔 때만 기다리고, 그 사이 들어온 활동은 최신 것만 남깁니다.
- **읽기 횟수:** 책장 이동 판단(10초 안에 5회)은 화면 반영 여부와 상관없이 이벤트가 올 때마다 셉니다. 책장에 이미 있으면 읽기가 이어지는 동안 머뭅니다.
- **위임은 팀장 자리에서:** 팀장이 책장이나 서버랙에 있을 때 위임하면 먼저 자리로 돌아오고, 팀원은 팀장 자리로 찾아옵니다.
- **서브에이전트 연결:** `Agent` 툴의 PreToolUse로 팀원을 먼저 만들고, `SubagentStart`나 툴 이벤트의 `agent_id`를 같은 종류의 대기 중인 팀원에 묶습니다. `SubagentStart`를 받은 팀원과 백그라운드 위임(`run_in_background`)은 `PostToolUse(Agent)`가 먼저 와도 `SubagentStop`까지 남고, 그 밖의 팀원은 `PostToolUse(Agent)`에서 보고합니다 (§4.1 M0 결과).
- **공동 팀장:** 같은 폴더에서 세션을 여러 개 열면 같은 팀에 "팀장 2", "팀장 3"이 생깁니다.
- **대사 선택:** 주어진 정보(작업 이름, 직원 이름, 명령)를 가장 많이 쓰는 줄을 우선 고릅니다. 모든 대사는 해요체이며, 테스트가 반말 대사를 잡아냅니다.
- **효과음 위치:** 직원 대기열 안의 효과음(말풍선 블립, 문 종, 보고 소리)은 그 동작과 함께 울리고, 알림성 소리(노크, 뾰롱, 띠리링)는 바로 울립니다. 승인 요청 노크는 말풍선 블립 없이 노크만 울립니다.

---

## 7. 말풍선과 대화 시스템

### 7.1 말풍선 종류

| 종류 | 모양 | 용도 |
|---|---|---|
| 말 (speech) | 둥근 사각형 + 꼬리 | 대화, 인사, 보고 |
| 생각 (thought) | 구름 + 작은 동그라미 꼬리 | 생각 중, 기다리는 중 |
| 외침 (shout) | 버터색 배경 + 굵은 테두리 + ❗ 배지 | **권한 승인 대기**, 중요 알림 |
| 속삭임 (whisper) | 작고 옅은 점선 테두리 | 휴게실 잡담 |
| 상태 칩 (status pill) | 머리 위 작은 알약 | 현재 툴과 대상 ("Edit · auth.ts") |

### 7.2 표시 규칙

- 캐릭터당 말풍선은 동시에 1개, 상태 칩은 별도 1개까지입니다.
- 표시 시간: `1.8초 + 글자당 60ms`, 최대 6초. 외침 풍선은 상황이 해결될 때까지 유지합니다.
- 길이: 미니 패널에서는 최대 18자, 메인 창에서는 최대 32자까지 보여주고 나머지는 `…`로 줄입니다. 마우스를 올리면 전체를 보여줍니다.
- 겹침 방지: 가까운 말풍선끼리 겹치면 위쪽으로 쌓고, 화면 가장자리에서는 꼬리 방향을 바꿉니다.
- 팀 구역당 동시에 보이는 말풍선은 최대 3개입니다. 넘치면 우선순위가 낮은 것부터 대기열에 넣습니다.

### 7.3 대화 스크립트

말풍선 문구는 `OfficeCore/Resources/dialogue.ko.json`에 템플릿으로 둡니다. 같은 상황이라도 여러 문구 중 무작위로 골라 단조롭지 않게 합니다.

```json
{
  "delegate.lead":   ["{task} 부탁해요!", "{member}님, {task} 좀 봐줄래요?", "이거 맡아줄 수 있어요?"],
  "delegate.member": ["맡겨주세요!", "네, 바로 볼게요!", "오케이~"],
  "report.member":   ["다 했어요!", "끝났습니다!", "정리해서 드릴게요"],
  "report.lead":     ["고마워요!", "역시 최고예요", "완벽해요 👍"],
  "permission":      ["{subject} 실행해도 될까요?", "이거 해도 돼요?", "승인 부탁드려요!"],
  "error":           ["어라…?", "앗, 다시 해볼게요", "이상하네…"],
  "idle.chat":       ["커피 맛있어요", "오늘 빌드 잘 되네요", "점심 뭐 먹을까요?"]
}
```

**대화 스크립트 예시 (위임)**

```
t=0.0  팀장   gesture(.beckon)   say("RouterConfig 리뷰 부탁해요!")
t=0.3  팀원   spawn(at: .door) → walk(to: 팀장 옆)
t=2.5  팀원   gesture(.nod)      say("맡겨주세요!")   express(.excited)
t=4.0  팀원   walk(to: 팀원석) → sit → pose(.reading)
```

- **말투는 모든 캐릭터가 밝고 정중한 해요체로 통일합니다** (확정). 감탄사("앗", "오!")와 짧은 문장으로 아기자기한 느낌을 냅니다. 반말, 과한 유행어, 업무와 무관한 농담은 쓰지 않습니다.
- 잡담은 휴게실에 2명 이상 있을 때만, 1분에 최대 1회 나옵니다.
- (v2) LLM으로 잡담을 생성하는 옵션을 검토합니다. 비용과 개인정보 문제로 기본값은 꺼둡니다.

### 7.4 개인정보 표시 수준

말풍선과 상태 칩에는 파일명과 명령어가 나올 수 있습니다. 회의에서 화면을 공유할 때를 생각해서 3단계로 설정할 수 있게 합니다.

| 수준 | 예시 |
|---|---|
| 상세 (기본) | "Edit · RouterConfig.java", "`npm test` 실행해도 될까요?" |
| 요약 | "파일 편집 중", "명령 실행해도 될까요?" |
| 비공개 | 아이콘과 표정만 표시 |

- 프롬프트 내용(`UserPromptSubmit.prompt`)은 어떤 수준에서도 말풍선에 표시하지 않습니다.
- 명령어에 들어 있는 토큰, 비밀번호처럼 보이는 문자열(`--password`, `token=`, 긴 hex/base64)은 상세 수준에서도 가립니다.

---

## 8. 사무실 화면 (SpriteKit)

### 8.1 시점과 맵

- **3/4 탑다운 정면 시점**을 씁니다. 캐릭터는 항상 화면 쪽을 보고 앉도록 책상을 배치해서 **표정이 늘 보이게** 합니다.
- 타일 크기는 32pt, 기본 맵은 30×18 타일(960×576pt)입니다.
- 팀이 4개를 넘으면 사무실이 아래로 확장되고, 메인 창에서 스크롤하거나 확대·축소(0.5~2배)할 수 있습니다.

```
┌──────────────────────────────────────────────────────────┐
│ [책장]     [창문][창문]   [화이트보드]  [출입문]   [서버랙] │  ← 뒷벽
│                                                          │
│   ┌─ 팀 섬 1 ─────────┐      ┌─ 팀 섬 2 ─────────┐       │
│   │ ★팀장  팀원  팀원  │      │ ★팀장  팀원  팀원  │       │
│   └───────────────────┘      └───────────────────┘       │
│                                                          │
│   ┌─ 팀 섬 3 ─────────┐      ┌─ 팀 섬 4 ─────────┐       │
│   │ ★팀장  팀원  팀원  │      │ ★팀장  팀원  팀원  │       │
│   └───────────────────┘      └───────────────────┘       │
│                                                          │
│ [리서치 코너: 지구본·의자]         [휴게실: 소파·커피머신·화분] │
└──────────────────────────────────────────────────────────┘
```

| 구역 | 연결 활동 |
|---|---|
| 팀 섬 (책상 1개 = 팀장석, 나머지 = 팀원석) | 기본 업무 |
| 책장 | 집중적인 파일 탐색 |
| 서버랙 | 오래 걸리는 셸 명령 |
| 화이트보드 | 계획 수립 (TodoWrite) |
| 리서치 코너 | 웹 검색 |
| 휴게실 | 대기, 잡담 |
| 출입문 | 출근, 퇴근 |

- 팀 섬마다 팀 색상의 러그를 깔고, 책상 앞에 프로젝트 이름 명패를 둡니다.
- 길찾기는 GameplayKit의 `GKGridGraph`(A*)를 씁니다. 가구 타일은 통과할 수 없게 처리합니다.

### 8.2 시간대와 다크 모드

- macOS가 다크 모드이면 **야간 사무실**로 바뀝니다. 창밖이 밤하늘이 되고, 스탠드 조명이 따뜻하게 켜지고, 바닥색이 어두워집니다.
- (선택) 실제 시각에 맞춰 아침, 낮, 노을, 밤 4단계로 창밖 풍경을 바꿉니다.

### 8.3 성능 목표

| 항목 | 목표 |
|---|---|
| 프레임 | 30fps (`preferredFramesPerSecond = 30`), 변화가 없으면 렌더링 일시 정지 |
| CPU | 대기 상태 1% 미만, 활동 중 5% 미만 (M1 맥북 기준) |
| 메모리 | 150MB 미만 |
| 지연 | 훅 발생부터 화면 반영까지 300ms 미만 |
| 가려짐 | 창이 가려지거나 최소화되면 씬을 일시 정지 (`occlusionState`) |

---

## 9. 아트 디렉션: "소프트 플랫 치비"

### 9.1 스타일 원칙

- **아기자기:** 2.2등신 치비 비율, 큰 머리, 짧은 팔다리, 볼 터치
- **세련됨:** 픽셀아트 대신 깔끔한 **플랫 벡터**. 채도를 살짝 낮춘 파스텔 팔레트와 일정한 두께의 부드러운 외곽선(진한 플럼색, 2pt)을 씁니다. 그림자는 반투명 타원 하나로 단순하게 처리합니다.
- **모양 언어:** 모든 모서리를 둥글게 처리하고, 직선과 날카로운 각을 피합니다.
- **절제:** 효과는 표정, 제스처, 말풍선에 집중하고, 배경은 차분하게 둡니다.

### 9.2 팔레트

| 토큰 | 주간 | 야간 | 용도 |
|---|---|---|---|
| `ink` | `#3A3247` | `#2A2436` | 외곽선, 텍스트 |
| `floor` | `#F1E6D6` | `#4A4258` | 바닥 |
| `wall` | `#E9EEF0` | `#3B3A52` | 벽 |
| `mint` | `#9FD8C7` | `#6FA99A` | 팀 색상 1, 식물 |
| `peach` | `#F6B9A0` | `#C98D78` | 팀 색상 2, 볼 터치 |
| `butter` | `#F7DE8B` | `#D9B95E` | 외침 풍선, 조명 |
| `lavender` | `#C7BCEB` | `#9A8FC4` | 팀 색상 3, 생각 풍선 |
| `sky` | `#A9D3F0` | `#1E2A4A` | 창밖, 땀방울 |
| `wood` | `#D9B48F` | `#8E7258` | 책상, 책장 |

### 9.3 캐릭터 리그 (종이인형 방식)

프레임 단위 애니메이션을 그리는 대신, **부위별 노드를 조합하고 움직이는** 방식을 씁니다. 그래야 적은 에셋으로 다양한 표정과 제스처를 만들 수 있습니다.

```
CharacterNode (SKNode)
├─ shadow
├─ legs (L, R)                    ← 걷기: 번갈아 위아래
├─ body                           ← 숨쉬기: 2.4초 주기로 살짝 위아래
├─ armBack  (어깨 기준 회전)       ← 제스처
├─ head (목 기준 회전)             ← 끄덕임, 갸웃
│  ├─ hairBack
│  ├─ face
│  ├─ blush (L, R)
│  ├─ eyes (L, R)                 ← 텍스처 교체로 표정, 2.5~5초마다 깜빡임
│  ├─ brows (L, R)
│  ├─ mouth
│  ├─ hairFront
│  ├─ accessory                   ← 안경, 헤드폰, 비니, 리본, 새싹
│  └─ fx (땀방울, 반짝이)
├─ armFront (어깨 기준 회전)
├─ prop (손에 든 소품)
└─ overlay: emote / statusPill / bubble
```

**표정 10종** (눈 + 눈썹 + 입 + 효과 조합)

| 표정 | 눈 | 입 | 효과 | 쓰이는 상황 |
|---|---|---|---|---|
| 기본 | 동그란 눈 | 작은 미소 | | 기본 |
| 기쁨 | ^ ^ | 활짝 웃는 입 | 볼 진하게 | 인사, 위임 |
| 집중 | 반쯤 감은 눈 | 일자 입 | 눈썹 아래로 | 읽기, 쓰기 |
| 생각 | 위를 보는 눈 | 작은 o | | 생각 중 |
| 놀람 | 큰 원 + 하이라이트 | O | 눈썹 위로 | 프롬프트 도착 |
| 곤란 | 기본 눈 | 물결 입 | 땀방울, 八자 눈썹 | 오류 |
| 졸림 | — — | 작은 입 | 💤 | 장시간 대기 |
| 뿌듯 | ✦ 별 눈 | 넓은 미소 | 반짝이 | 완료 |
| 슬픔 | ㅠ ㅠ | 시무룩 | 눈물 줄 | 연속 오류 |
| 간절 | 반짝이는 큰 눈 | 벌린 입 | ❗ | 권한 승인 대기 |

**제스처 12종**

| 제스처 | 구현 |
|---|---|
| 손 흔들기 | 팔 들고 좌우 회전 반복 |
| 타이핑 | 양팔 앞으로, 빠른 미세 진동 |
| 턱 괴기 | 한 팔 접어 얼굴 아래, 고개 살짝 기울기 |
| 손 들기 | 한 팔 위로 쭉, 몸 살짝 위아래 |
| 엄지척 | 한 팔 앞으로 + 엄지 손 텍스처 |
| 만세 | 양팔 위로 + 작은 점프 |
| 하이파이브 | 두 캐릭터가 마주 보고 손 맞대기 + 반짝 효과 |
| 고개 갸웃 | 머리 15° 회전 |
| 머리 긁적 | 팔을 머리 옆으로, 손 흔들기 |
| 기지개 | 양팔 위로 천천히 + 몸 늘이기 |
| 커피 마시기 | 컵 소품 + 팔 들어 올리기 |
| 끄덕임 | 머리 위아래 2회 |

### 9.4 외형 생성

- 고정 직원은 `name` 해시를 시드로 외형을 정합니다. 피부 톤 4종, 헤어스타일 6종, 머리색 8종, 상의색(팔레트), 액세서리 6종입니다.
- 팀장은 가슴에 작은 별 배지를 달고, 책상에 화분이 놓입니다.
- 임시 직원은 머리에 새싹 🌱을 답니다.
- 설정에서 직원마다 외형과 표시 이름(예: `code-reviewer` → "리뷰 담당 지원")을 바꿀 수 있습니다.

### 9.5 에셋 파이프라인

1. 캐릭터 부위와 가구를 **SVG로 직접 제작**합니다. 라이선스 문제가 없습니다.
2. `Assets.xcassets`에 벡터(PDF/SVG, "Preserve Vector Data")로 넣습니다.
3. 실행할 때 화면 배율(2x, 3x)에 맞춰 `SKTexture`로 래스터화하고 캐시합니다.
4. 말풍선 글꼴은 **고운돋움(Gowun Dodum, OFL)**을 앱에 번들합니다. 라벨 등 UI는 시스템 글꼴을 씁니다.

---

## 10. 앱 화면 구성 (SwiftUI + AppKit)

| 화면 | 구현 | 내용 |
|---|---|---|
| **메뉴바** | `MenuBarExtra(.window)` | 아이콘: 작은 건물 + 상태 점(초록: 작업 중, 노랑: 승인 대기, 회색: 쉬는 중). 승인 대기는 숫자 배지. 드롭다운에 팀별 에이전트 목록, 승인 대기 항목은 맨 위에 고정. 버튼: 사무실 열기, 미니 사무실 켜기/끄기, 설정 |
| **미니 사무실** | `NSPanel` (`.nonactivatingPanel`, `.resizable`, `.floating`, `.canJoinAllSpaces`, `.fullScreenAuxiliary`) | 기본 360×240, 화면 오른쪽 아래. 포커스를 빼앗지 않음, 전체화면 IDE 위에도 표시. **크기 자유 조절**, 드래그 이동, 배경 투명도 조절 (§10.1) |
| **메인 창** | `NavigationSplitView` | 왼쪽 팀 목록 / 가운데 큰 사무실 / 오른쪽 인스펙터(선택한 직원의 현재 작업, 최근 이벤트 타임라인, 팀원 목록, "터미널로 이동" 버튼) |
| **설정** | `Settings` scene | 일반(로그인 시 실행: `SMAppService`), 연동(훅 설치·제거·상태 확인, 포트, 테스트 이벤트 보내기), 표시(말풍선 상세도, 미니 사무실 투명도, 동작 줄이기), 알림, **효과음**(§11), 직원 꾸미기 |

**상호작용**

- 캐릭터에 마우스 올리기: 이름표와 현재 작업 전체 문구
- 클릭: 인스펙터에서 상세 보기
- 더블클릭: 해당 세션의 터미널 앱을 앞으로 가져오기. `X-Office-Term` 값으로 앱을 고르고, VS Code이면 `cwd`를 엽니다. 특정 탭까지 찾아가는 기능은 v2에서 iTerm2부터 지원합니다.
- macOS **"동작 줄이기"** 설정을 따릅니다. 켜져 있으면 걷기 대신 순간이동하고, 제스처를 생략합니다.

**알림 (UNUserNotification)**

- 권한 승인 대기: 즉시 알림 + 메뉴바 배지
- 응답 완료(Stop): 기본은 끄고, 설정에서 켤 수 있습니다
- 알림을 클릭하면 해당 터미널로 이동합니다

### 10.1 미니 사무실 크기와 위치

**위치**

- 기본 위치는 화면 **오른쪽 아래**, 가장자리에서 16pt 떨어진 곳입니다.
- 드래그로 옮길 수 있습니다. 화면 모서리 근처(40pt 이내)에 놓으면 모서리에 자석처럼 붙습니다.
- **디스플레이마다** 마지막 위치와 크기를 기억합니다. 외장 모니터를 연결하거나 뺄 때 그 화면에서 쓰던 상태로 돌아갑니다.
- 창이 화면 밖으로 벗어나면(해상도 변경 등) 기본 위치로 되돌립니다.

**크기**

- 창의 가장자리나 모서리를 드래그해서 **자유롭게 늘리고 줄일 수 있습니다.** 최소 200×130pt, 최대는 화면의 사용 가능 영역 전체입니다.
- 기본은 비율 제한이 없고, ⌥(Option)를 누른 채 조절하면 현재 비율을 유지합니다.
- 크기 프리셋: 작게 240×160 / 보통 360×240 / 크게 560×360 / 화면 절반. 우클릭 메뉴와 메뉴바에서 고를 수 있습니다.
- 위쪽 손잡이를 더블클릭하면 "작게"와 직전 크기 사이를 오갑니다.
- 크기 조절 손잡이와 제목줄은 마우스를 올렸을 때만 나타납니다. 평소에는 사무실만 보입니다.

**카메라 (창 크기가 바뀔 때 보이는 범위)**

| 모드 | 동작 |
|---|---|
| 맞춤 (기본) | 선택한 범위가 창에 꽉 차도록 자동으로 확대·축소합니다. 범위는 사무실 전체 / 한 팀 / 따라가기(가장 바쁜 팀) 중에서 고릅니다 |
| 고정 배율 | 배율은 그대로 두고, 창을 키우면 더 넓은 영역이 보입니다 |

- 패널 안에서 트랙패드 핀치나 ⌘+스크롤로 확대·축소하고, 드래그로 화면을 옮길 수 있습니다. 더블클릭하면 맞춤 상태로 돌아갑니다.

**크기에 따른 표시 단계**

창이 작아질수록 글자가 뭉개지지 않게 보여주는 정보를 줄입니다. 기준은 창 크기가 아니라 **실제 표시 배율**(타일 32pt가 화면에서 차지하는 크기)입니다.

| 표시 배율 | 보여주는 것 |
|---|---|
| 0.5 미만 | 캐릭터, 표정, 머리 위 아이콘만. 말풍선은 외침 풍선만 (최대 10자) |
| 0.5 ~ 0.8 | 말풍선 최대 18자, 상태 칩 숨김, 명패 숨김 |
| 0.8 이상 | 말풍선 최대 32자, 상태 칩과 명패 표시 |

**구현 메모**

- `NSPanel` 스타일: `.nonactivatingPanel`, `.resizable`, `.titled` + `.fullSizeContentView`, 제목줄은 숨김. `contentMinSize`로 최솟값을 지정합니다.
- `SKView`는 `scaleMode = .resizeFill`로 두고, 창 크기가 바뀌면 `SKCameraNode`의 배율을 다시 계산합니다.
- 위치와 크기는 `NSScreen`의 디스플레이 ID를 키로 `UserDefaults`에 저장합니다.
- 크기 조절 중에는 렌더링을 30fps로 유지하고, 표시 단계는 조절이 끝난 뒤 0.2초 후에 바꿔서 깜빡임을 막습니다.

---

## 11. 효과음

### 11.1 원칙

- **작고 아기자기하게:** 길이 0.05~0.6초, 기본 음량 35%. 실로폰, 마림바, 오르골처럼 부드러운 톤만 씁니다. 날카로운 고음, 경고음, 긴 소리는 쓰지 않습니다.
- **종류별로 켜고 끕니다.** 전체 음소거와 전체 음량은 따로 있습니다.
- **알림성과 장식성을 구분합니다.** 놓치면 안 되는 소리(승인 요청, 완료)는 사무실이 안 보여도 울리고, 분위기용 소리는 사무실이 화면에 보일 때만 울립니다.
- **모두 직접 합성합니다.** 녹음 파일이나 외부 음원을 쓰지 않아 라이선스 문제가 없습니다.

### 11.2 효과음 목록

| 설정 항목 | 소리 | 언제 | 기본값 | 구분 |
|---|---|---|---|---|
| 승인 요청 | **똑똑** (나무 노크 2번) | 권한 승인 대기가 시작될 때. 30초마다 최대 2회 더 | 켬 | 알림 |
| 입력 대기 | **뾰롱** (부드러운 2음 하강) | Claude가 응답을 마치고 내 입력을 기다릴 때 | 켬 | 알림 |
| 작업 완료 | **띠리링** (실로폰 3음 상승) | 팀장 응답 완료(Stop). 팀원 보고(SubagentStop)는 더 짧은 2음 | 켬 | 알림 |
| 말풍선 | **톡 + 짧은 음절 블립 2~4개** | 말풍선이 뜰 때 (잡담 제외) | 켬 | 장식 |
| 출근·퇴근 | **딸랑** (작은 문 종) | 세션 시작·종료, 팀원 출근·퇴근 | 켬 | 장식 |
| 오류 | **뿅?** (낮은 음이 살짝 내려감) | 툴 오류 | 켬 | 장식 |
| 잡담 | 아주 작은 블립 | 휴게실 속삭임 | 끔 | 장식 |
| 발소리 | **톡톡** | 캐릭터가 걸을 때 | 끔 | 장식 |
| 타이핑 | 아주 작은 키보드 소리 | 편집 중 | 끔 | 장식 |

### 11.3 재생 규칙

- **전체 음소거:** 설정과 메뉴바 드롭다운에서 바로 켜고 끕니다.
- **전체 음량:** 0~100%, 기본 35%. 각 항목에는 미리 듣기 버튼이 있습니다.
- **장식성 소리:** 미니 사무실이나 메인 창이 화면에 보일 때만 재생합니다.
- **집중 모드 존중** (기본 켬): macOS 집중 모드가 켜져 있으면 알림성 소리도 끕니다. 시각 알림은 그대로 둡니다.
- **연속 재생 제한:** 같은 항목은 최소 간격을 둡니다(말풍선 0.4초, 완료 2초, 출근 1초). 동시에 울리는 소리는 최대 3개입니다.
- **우선순위:** 승인 요청 > 입력 대기 > 작업 완료 > 오류 > 나머지. 슬롯이 꽉 차면 낮은 소리부터 생략합니다.

### 11.4 캐릭터 목소리 (말풍선 블립)

- 직원마다 기본 음높이가 있습니다. 프로필 키의 해시로 5단계 중 하나를 고르며, 고정 직원은 항상 같은 목소리입니다.
- 말풍선 글자 수에 따라 블립을 2~4개 재생하고, 블립마다 ±2반음 범위에서 무작위로 음을 바꿉니다.
- 단어를 흉내 내는 음성 합성은 하지 않습니다. 짧은 톤만 씁니다.

### 11.5 구현

- `OfficeCore`에 `SoundCue`(무엇을 울릴지)와 `SoundRecipe`(파형, 음 목록, 엔벨로프)를 **데이터로** 정의합니다. 리눅스에서도 테스트할 수 있습니다.
- 연출 엔진은 `Directive.sound(SoundCue)`를 내보내고, 앱의 `SoundPlayer`가 설정(켜짐 여부, 음량, 연속 재생 제한)을 확인한 뒤 재생합니다.
- 앱이 시작될 때 레시피로 `AVAudioPCMBuffer`를 미리 합성해 둡니다. 재생은 `AVAudioEngine` + `AVAudioPlayerNode` 4개 풀, 캐릭터별 음높이는 `AVAudioUnitTimePitch`를 씁니다.
- 설정은 `UserDefaults`에 `sound.enabled`, `sound.volume`, `sound.<항목>.enabled`로 저장합니다.
- [스타일 미리보기](preview/index.html)의 효과음 섹션은 같은 레시피를 Web Audio로 들려주는 시안입니다.

---

## 12. 보안과 배포

### 12.1 로컬 서버 보안

- `127.0.0.1`에만 바인딩합니다. 외부 네트워크에서는 접근할 수 없습니다.
- 모든 요청에 `X-Office-Token`을 검증합니다. 토큰은 앱이 실행될 때마다 새로 만들어 `endpoint` 파일(권한 600)에 기록합니다.
- `Origin` 헤더가 있는 요청은 거부합니다. 웹 페이지가 브라우저를 통해 로컬 서버를 호출하는 공격(CSRF, DNS 리바인딩)을 막기 위해서입니다.
- 본문 크기는 1MB로 제한하고, JSON만 받습니다.
- 받은 데이터는 메모리에만 두고(세션당 최근 1,000건), 디스크에는 직원 프로필과 설정만 저장합니다.

### 12.2 배포

- **샌드박스를 쓰지 않는 앱**입니다. `~/.claude`를 읽고 `settings.json`을 수정해야 하기 때문입니다. 따라서 App Store에는 내지 않습니다.
- 1단계: **소스 빌드** (`make install`). 연회비가 필요 없습니다.
- 2단계(선택): Developer ID 서명 + 공증, DMG, Sparkle 자동 업데이트, Homebrew Cask
- 앱 이름에 "Claude"가 들어가므로, 불특정 다수에게 공개 배포할 때는 Anthropic의 상표 사용 정책을 먼저 확인합니다. 본인용과 소스 빌드 단계에서는 해당 없습니다.

---

## 13. 저장소 구조

```
claude-office/
├─ Package.swift                    # OfficeCore 라이브러리 + 테스트 + 도구 (Linux 빌드 가능)
├─ Sources/
│  ├─ OfficeCore/
│  │  ├─ Support/      JSONValue(키 순서 보존 파서), StableHash, SeededRandom
│  │  ├─ Hooks/        HookParser, HookSettingsEditor(settings.json 병합), ClaudeVersion, AgentDefinition
│  │  ├─ Model/        OfficeEvent, ToolCall/ToolCatalog, Agent/Team/AgentProfile/Appearance, OfficeState(리듀서)
│  │  ├─ Engine/       Choreographer, Directive, OfficeEngine(진입점)
│  │  ├─ Dialogue/     DialogueBook, PrivacyLevel, Redactor(민감 정보 가리기)
│  │  ├─ Sound/        SoundCue/SoundGroup, SoundRecipe/SoundLibrary/SoundRenderer(합성), SoundPolicy
│  │  └─ Resources/    dialogue.ko.json
│  └─ office-sim/      # 시나리오 → 연출 타임라인 출력, 효과음 WAV 렌더링 (M2에서 앱으로 보내는 replay 추가)
├─ Scenarios/          # office-sim용 시나리오 (JSON Lines)
├─ Tests/OfficeCoreTests/
│  └─ Fixtures/
│     ├─ synthetic/    # 2.1.318 훅 스키마 기준 합성 픽스처
│     └─ captured/     # M0에서 수집한 실제 훅 페이로드 (export 결과)
├─ App/                             # macOS 전용 (Xcode 필요)
│  ├─ project.yml                   # XcodeGen 설정 → ClaudeOffice.xcodeproj 생성
│  ├─ Sources/
│  │  ├─ App/          ClaudeOfficeApp, MenuBar, MiniOfficePanel, MainWindow, Settings
│  │  ├─ Server/       HookServer (Network.framework NWListener)
│  │  ├─ Scene/        OfficeScene, CharacterNode, BubbleNode, Pathfinder, Furniture
│  │  └─ System/       Notifier, TerminalFocuser, LoginItem, SoundPlayer
│  └─ Resources/       Assets.xcassets(SVG 벡터), Fonts/GowunDodum
├─ scripts/
│  ├─ claude-office.sh             # 훅 스크립트
│  ├─ capture-hook.sh              # M0: 실제 페이로드를 이벤트마다 파일로 저장
│  └─ capture.py                   # M0: 수집 훅 설치·제거, 구조 리포트, 픽스처 내보내기
├─ docs/
│  ├─ DESIGN.md                    # 이 문서
│  ├─ M0-capture.md                # 훅 페이로드 수집 안내
│  └─ preview/index.html           # 스타일 미리보기
└─ Makefile                        # bootstrap / test / app / install / uninstall
```

**Makefile 대상**

| 대상 | 내용 |
|---|---|
| `make test` | `swift test` (OfficeCore, Linux에서도 실행 가능) |
| `make demo` | `office-sim`으로 `Scenarios/delegation.jsonl`의 연출 타임라인 출력 |
| `make sounds` | 효과음을 `build/sounds/*.wav`로 렌더링 |
| `make bootstrap` | (M2) `brew install xcodegen` 후 프로젝트 생성 |
| `make app` / `make install` | (M2) `xcodebuild`로 Release 빌드 / `/Applications`에 복사 |

---

## 14. 개발 방법과 테스트

### 14.1 작업 위치

| 작업 | 위치 |
|---|---|
| OfficeCore (파서, 리듀서, 연출 엔진, 대화) | 클라우드 세션(리눅스)에서도 가능 |
| SwiftUI, SpriteKit, AppKit 코드 작성 | 어디서든 작성할 수 있지만, **빌드와 확인은 맥에서만** 가능 |
| UI 다듬기, 애니메이션 튜닝 | 개발 노트북의 로컬 Claude Code + Xcode |

### 14.2 테스트 전략

- **단위 테스트 (swift-testing):** 픽스처 JSON → `OfficeEvent` 파싱, 리듀서 상태 전이, 깜빡임 방지 규칙(가짜 시계), 대화 템플릿 치환, 민감 정보 가리기, 훅 설치기의 병합·제거 멱등성
- **시나리오 재생:** `office-replay scenario.jsonl --speed 2`로 녹화한 세션을 앱에 다시 보냅니다. Claude Code 없이도 화면을 확인할 수 있습니다.
- **데모 모드:** 앱 안에서 가짜 이벤트를 생성하는 디버그 메뉴
- **수동 점검표 (맥):** 전체화면 IDE 위 표시, Space 전환, 다크 모드 전환, 동작 줄이기, 앱 종료 상태에서 Claude Code 정상 동작

---

## 15. 마일스톤

| 단계 | 내용 | 완료 기준 |
|---|---|---|
| **M0** 준비 ✅ | 수집 도구(`scripts/capture.py`), **실제 페이로드 수집** (사용자 맥, [안내](M0-capture.md)), 저장소 골격 | 2.1.318 실제 리포트·집계로 §4 필드와 서브에이전트 유형 확정 |
| **M1** 코어 ✅ | 이벤트 모델, 파서, 리듀서, 연출 엔진, 대화 템플릿, 효과음 레시피·합성·정책, 단위 테스트 74개, `office-sim` | `swift test` 통과 (Swift 6.2.3, Linux) |
| **M2** 앱 뼈대 | 메뉴바 앱, HookServer, 텍스트 목록 UI, 훅 설치기 | 실제 Claude Code 이벤트가 메뉴바 목록에 실시간 표시 |
| **M3** 사무실 | 맵, 가구, 캐릭터 리그, 길찾기, 자리 활동 | 출근, 업무, 퇴근 흐름이 화면에 보임 |
| **M4** 표현 | 표정 10종, 제스처 12종, 말풍선 5종, 대화 스크립트, **효과음** | 위임, 승인 대기, 완료 보고 연출과 소리 동작 |
| **M5** 편의 | 미니 사무실 패널(크기 조절, 표시 단계), 알림, 인스펙터, 설정, 터미널 이동 | 하루 동안 실사용 |
| **M6** 다듬기 | 야간 모드, 성능 목표 달성, 접근성, `make install` 배포 | §8.3 목표 충족 |

---

## 16. 위험 요소와 대응

| 위험 | 대응 |
|---|---|
| Claude Code 업데이트로 훅 페이로드가 바뀜 | 관대한 파서, 알 수 없는 필드 무시, 버전별 픽스처 테스트 |
| 서브에이전트 내부 활동을 누가 했는지 알 수 없음 | 2.1.318부터는 `agent_id`로 해결. 구버전은 §4.4 대비책으로 처리 |
| 효과음이 거슬려서 꺼버림 | 기본 음량 35%, 장식성 소리는 일부만 기본 켬, 연속 재생 제한, 항목별 토글 |
| 툴 호출이 너무 잦아 화면이 정신없음 | §6.3 깜빡임 방지 규칙, 데모 시나리오로 튜닝 |
| 직접 그린 그래픽의 완성도 | 종이인형 리그로 에셋 수를 최소화. 미리보기로 스타일을 먼저 합의하고, 나중에 디자이너 에셋으로 교체할 수 있게 부위 규격을 고정 |
| 리눅스에서 UI를 빌드할 수 없음 | 코어/UI 분리, UI 작업은 맥 로컬 세션에서 |
| 화면 공유 중 정보 노출 | §7.4 표시 수준, 프롬프트 비표시, 민감 문자열 가리기 |

---

## 17. 결정 기록

| 날짜 | 항목 | 결정 |
|---|---|---|
| 2026-11-06 | 캐릭터 단위 | 세션 = 팀장, 서브에이전트 = 팀원, 직접 정의한 에이전트 = 고정 직원 |
| 2026-11-06 | 사무실 구성 | 한 사무실 + 프로젝트별 팀 구역 |
| 2026-11-06 | 상호작용 | 보기 + 알림 + 상세 이동 (승인·지시는 v2 검토) |
| 2026-11-06 | 에셋 | 그래픽·효과음 모두 직접 제작 |
| 2026-11-06 | 앱 이름 | Claude Office |
| 2026-11-06 | 캐릭터 말투 | 해요체 통일 |
| 2026-11-06 | 효과음 | 작고 아기자기한 합성음, 항목별 켜기·끄기 |
| 2026-11-06 | 미니 사무실 | 오른쪽 아래 기본, 크기 자유 조절 |
