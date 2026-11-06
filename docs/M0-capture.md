# M0: 실제 훅 페이로드 수집 안내

Claude Office의 파서는 **사용 중인 Claude Code가 실제로 보내는 데이터**를 기준으로 만듭니다.
개발 노트북(macOS)에서 아래 순서대로 한 번만 진행해 주세요. 20~30분이면 충분합니다.

## 준비물

- macOS 개발 노트북, Claude Code 최신 버전 (`claude --version`)
- `python3` (Xcode Command Line Tools에 포함되어 있습니다. 없으면 `xcode-select --install`)
- 이 저장소 클론

```bash
git clone https://github.com/engyjoon/claude-office.git
```

```bash
cd claude-office && git checkout claude/magical-johnson-4jfy9c
```

## 1. 수집 훅 설치

```bash
python3 scripts/capture.py install
```

- `~/.claude/settings.json`을 백업한 뒤 수집 훅만 추가합니다. 기존 훅과 설정은 그대로 둡니다.
- Claude Code 2.1.318 이상이면 `SubagentStart`, `PermissionRequest`, `PermissionDenied`, `PostToolUseFailure`, `StopFailure`도 함께 등록합니다.
- 수집 훅은 아무것도 출력하지 않고 바로 끝나므로 Claude Code 사용에는 영향이 없습니다.

설치 후 **새 터미널**에서 `claude`를 실행하고 `/hooks`를 입력해 이벤트 목록이 보이는지 확인해 주세요.
설정 오류 경고가 뜨면 아래 명령으로 기본 이벤트만 다시 설치합니다.

```bash
python3 scripts/capture.py install --basic
```

## 2. 수집 시나리오

**회사 코드가 아닌 연습용 폴더**에서 진행하시길 권합니다. 원본에는 파일 내용과 프롬프트가 그대로 저장되기 때문입니다.

```bash
mkdir -p ~/office-capture-demo && cd ~/office-capture-demo && git init
```

이 폴더에서 `claude`를 실행하고 아래 순서로 요청해 주세요. 각 항목이 어떤 이벤트를 만들어내는지 함께 적었습니다.

| 순서 | 요청 예시 | 확인하려는 이벤트 |
|---|---|---|
| 1 | "간단한 Python 계산기 모듈과 테스트 파일을 만들어줘" | Write, Edit, Bash(테스트 실행), Stop |
| 2 | "프로젝트 파일 구조를 살펴보고 요약해줘" | Read, Glob, Grep 연속 호출 |
| 3 | "general-purpose 서브에이전트 두 개를 동시에 써서 하나는 README를, 하나는 테스트를 보강해줘" | Task/Agent, SubagentStart/Stop, `agent_id` |
| 4 | 직접 정의한 에이전트가 있다면: "code-reviewer 에이전트로 리뷰해줘" | 고정 직원용 `agent_type` |
| 5 | 권한을 묻는 명령이 나오면 **바로 승인하지 말고 30초 정도 기다렸다가** 승인 | Notification(permission_prompt), PermissionRequest |
| 6 | 한 번은 거부해 보기 | PermissionDenied 등 |
| 7 | "SpriteKit 공식 문서에서 SKAction 사용법을 찾아줘" | WebSearch, WebFetch |
| 8 | 존재하지 않는 파일 읽기 요청 | PostToolUseFailure (툴 오류) |
| 9 | 응답이 끝난 뒤 1~2분 그대로 두기 | Notification(idle_prompt) |
| 10 | `/compact` 실행 후 `/exit` | PreCompact, SessionEnd |

가능하면 VS Code 터미널과 iTerm2(또는 기본 터미널) 양쪽에서 한 번씩 실행해 주세요. "터미널로 이동" 기능에 필요한 `TERM_PROGRAM` 값을 확인합니다.

## 3. 결과 확인과 공유

```bash
python3 scripts/capture.py status
```

```bash
python3 scripts/capture.py report
```

`report`는 **값을 모두 지우고 키와 타입만** 남긴 요약입니다. `~/claude-office-capture/report.md`에 저장되며, 이 내용은 그대로 공유하셔도 됩니다.

```bash
python3 scripts/capture.py breakdown
```

`breakdown`은 서브에이전트마다 어떤 이벤트가 어떤 순서로 왔는지, 시작만 있고 끝이 없는 툴 호출이 무엇인지 집계합니다. `agent_id`는 S1, S2…로 바꾸고 툴의 입력·출력 값은 넣지 않으므로 그대로 공유하셔도 됩니다 (`~/claude-office-capture/breakdown.md`).

테스트 픽스처는 아래 명령으로 만듭니다.

```bash
python3 scripts/capture.py export
```

- `Tests/OfficeCoreTests/Fixtures/captured/`에 이벤트·툴 조합마다 최대 3개씩 저장합니다.
- 프롬프트, 파일 내용, 편집 내용, 명령 출력은 길이만 남기고 가립니다.
- 홈 경로는 `~`로, 프로젝트 경로는 `~/work/project-N`으로 바꿉니다.
- `password=`, `token`, `API_KEY` 같은 값과 긴 hex/base64 문자열은 `<가림>`으로 바꿉니다.
- 그래도 **커밋하기 전에 파일을 직접 열어** 서버 주소, 사내 시스템 이름, 계정 정보가 남아 있지 않은지 확인해 주세요.

## 4. 정리

```bash
python3 scripts/capture.py uninstall
```

수집 훅만 제거하고 다른 설정은 그대로 둡니다. 원본(`~/claude-office-capture/raw/`)은 필요 없으면 직접 지워 주세요.

```bash
rm -rf ~/claude-office-capture
```
