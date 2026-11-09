# 다른 맥에 설치하기

Claude Office를 새 맥(예: 회사 맥북)에 설치하는 방법입니다. **그 맥에서 저장소를 클론해 직접 빌드**하는 것을 기본으로 합니다.

> **Claude Code에게:** 사용자가 이 저장소를 새 맥에 클론하고 설치·빌드·첫 실행을 물으면 이 문서를 따라 안내해 주세요.
> - 사용자는 코드 서명·Gatekeeper·Xcode 설정에 익숙하지 않을 수 있습니다. 한국어로, 한 단계씩, 그 명령이 무엇을 하는지 쉬운 말로 설명해 주세요.
> - 먼저 [1. 시작 전 확인](#1-시작-전-확인-5분)의 명령을 직접 실행해 결과를 읽고, 이 맥에서 막힐 곳이 있는지 알려 준 뒤 진행하세요.
> - `sudo`가 필요한 명령, Xcode·Homebrew 설치, 시스템 설정 변경은 사용자가 직접 하도록 안내하고, 왜 필요한지 설명하세요.
> - `~/.claude/settings.json`은 손으로 고치지 말고 앱의 "훅 설치" 버튼을 쓰게 하세요 (앱이 백업한 뒤 Claude Office 훅만 넣고 뺍니다).
> - 문제가 생기면 [5. 문제가 생겼을 때](#5-문제가-생겼을-때)를 먼저 보세요.

## 왜 그 맥에서 빌드하나요?

이 앱은 Apple 개발자 계정 없이 만든 **로컬(ad-hoc) 서명** 앱입니다 (`App/project.yml`의 `CODE_SIGN_IDENTITY: "-"`).

- **그 맥에서 직접 빌드한 앱**에는 인터넷에서 받은 파일에 붙는 격리 표시(`com.apple.quarantine`)가 없어서, macOS가 막지 않고 그냥 열립니다.
- **다른 맥에서 만든 앱을 AirDrop·메신저·브라우저로 받으면** 격리 표시가 붙어, 처음 열 때 "확인되지 않은 개발자" 경고로 막힙니다. ([부록: 빌드한 앱을 옮겨 설치하기](#부록-빌드한-앱을-옮겨-설치하기))
- 업데이트도 `git pull && make install` 한 줄로 끝납니다.

## 1. 시작 전 확인 (5분)

터미널에서 아래 명령을 실행해 결과를 확인합니다.

```bash
sw_vers -productVersion
```

```bash
uname -m
```

```bash
xcodebuild -version
```

```bash
command -v brew xcodegen git claude
```

```bash
id -Gn | tr ' ' '\n' | grep -x admin
```

```bash
profiles status -type enrollment
```

```bash
cat "/Library/Application Support/ClaudeCode/managed-settings.json"
```

```bash
ls ~/Library/Application\ Support/Claude/claude-code-sessions
```

```bash
df -h ~
```

| 확인 | 기준 | 안 맞으면 |
|---|---|---|
| macOS 버전 | **14.0 이상** (앱 최소 버전). 최신 Xcode를 깔려면 더 높아야 할 수 있음 | 14 미만이면 실행 불가 |
| 칩 (`arm64` / `x86_64`) | 둘 다 됨 | — |
| Xcode | 있으면 버전 확인. 집 맥미니는 **Xcode 26.6**에서 빌드함 | 없으면 [2단계](#2-준비-처음-한-번)에서 설치 |
| brew · xcodegen · git · claude | 각각 경로가 나오면 설치된 것 | 없는 것은 2단계에서 설치. `claude`가 없으면 훅이 쓸모없음 |
| 관리자 계정 (`admin`이 출력됨) | 관리자면 편함 | 아니면 Xcode·Homebrew 설치, `/Applications` 복사가 막힐 수 있음 → 회사 IT에 문의 |
| MDM 등록 (`Enrolled via DEP: Yes` 또는 `MDM enrollment: Yes`) | 회사가 관리하는 맥 | App Store·앱 실행 제한이 있을 수 있음 |
| **managed-settings.json** | 파일이 없거나, `"allowManagedHooksOnly": true`·`"disableAllHooks": true`가 **없어야** 함 | 있으면 회사가 개인 훅을 막은 것. **어떻게 설치해도 앱이 이벤트를 못 받음** → 회사 정책 확인 |
| 데스크톱 앱 세션 폴더 | 있으면 Claude 데스크톱 앱 세션도 보임 | 없으면 터미널 `claude` 세션만 보임 |
| 디스크 여유 | Xcode를 새로 깔면 **10GB 이상** | 공간 확보 |

## 2. 준비 (처음 한 번)

### Xcode

앱 화면(SwiftUI·SpriteKit)과 아이콘(에셋 카탈로그)을 빌드하려면 **전체 Xcode**가 필요합니다. Command Line Tools만으로는 안 됩니다.

1. App Store에서 **Xcode**를 설치합니다 (수 GB, 30분~1시간). App Store를 못 쓰면 https://developer.apple.com/download/all/ 에서 받을 수 있습니다 (Apple 계정 필요).
2. Xcode를 **한 번 실행**해 추가 구성요소 설치와 약관 동의를 마칩니다.
3. 터미널에서 확인합니다.

```bash
xcodebuild -version
```

`xcode-select`가 Command Line Tools를 가리키고 있어도 `Makefile`이 `/Applications/Xcode.app`을 알아서 찾습니다. Xcode를 다른 곳에 깔았다면 아래처럼 지정합니다.

```bash
sudo xcode-select -s /Applications/Xcode.app
```

### Homebrew와 XcodeGen

`App/ClaudeOffice.xcodeproj`는 저장소에 없고, 빌드할 때 XcodeGen이 `App/project.yml`로 만듭니다.

Homebrew가 없으면 https://brew.sh 의 안내대로 설치합니다 (관리자 암호 필요). 그다음:

```bash
brew install xcodegen
```

Homebrew를 쓸 수 없는 맥이면 https://github.com/yonaskolb/XcodeGen/releases 의 `xcodegen.zip`을 받아 `xcodegen` 명령이 PATH에서 보이게 둬도 됩니다.

## 3. 받기와 설치

저장소는 공개이고, 작업 브랜치(`claude/magical-johnson-4jfy9c`)가 기본 브랜치라 그냥 클론하면 됩니다.

```bash
git clone https://github.com/engyjoon/claude-office.git
```

```bash
cd claude-office
```

```bash
make install
```

`make install`은 XcodeGen으로 프로젝트를 만들고(`make bootstrap`), Release로 빌드한 뒤(`make app`, 몇 분), `/Applications/Claude Office.app`에 복사합니다. 결과물은 인텔·Apple 칩 겸용(universal)입니다.

빌드 전에 코어만 확인해 보려면 `make test`를 먼저 실행해도 됩니다 (Xcode 없이 Swift 6 툴체인만으로 됨).

## 4. 처음 실행 (그 맥에서 한 번)

설정은 맥마다 따로 저장되므로 집 맥의 설정은 옮겨 오지 않습니다.

1. 앱을 엽니다. Dock에는 안 보이고 **메뉴바에 아이콘**만 생깁니다.
   ```bash
   open "/Applications/Claude Office.app"
   ```
2. **알림** 권한 창 → "허용" (승인 대기·답변 필요 알림). **집중 모드** 권한 창 → "허용" (집중 모드 중 효과음 줄이기, 안 해도 동작).
3. 메뉴바 아이콘 → "Claude Code 훅이 설치되어 있지 않아요" 배너의 **설치**.
   - `~/.claude/hooks/claude-office.sh`를 쓰고, `~/.claude/settings.json`을 `settings.json.bak-날짜`로 백업한 뒤 Claude Office 훅만 추가합니다.
4. **새로 연** Claude Code 세션부터 사무실에 나타납니다. 이미 열려 있던 세션은 훅을 다시 읽지 않으니 새로 시작하세요.
5. **설정… → 연동 → 테스트 이벤트 보내기**: 가짜 직원이 출근했다가 약 11초 뒤 퇴근하면 훅 → 앱 연결이 된 것입니다.
6. (선택) **설정… → 일반 → 로그인 시 실행** 켜기. "승인 필요"가 뜨면 "시스템 설정 열기" → 로그인 항목에서 Claude Office를 허용합니다. 로컬 서명 앱이라 macOS가 따로 승인을 요구하거나, 다시 설치한 뒤 꺼질 수 있습니다.

앱이 쓰는 위치 (모두 그 맥 사용자 폴더 안):

| 위치 | 내용 |
|---|---|
| `~/.claude/hooks/claude-office.sh` | 훅 스크립트 (`curl`로 앱에 이벤트 전송) |
| `~/.claude/settings.json` | 훅 등록 (설치·제거 때 백업) |
| `~/Library/Application Support/ClaudeOffice/endpoint` | 앱의 포트와 토큰. 앱이 실행될 때마다 새로 씀 |
| `~/Library/Application Support/Claude/claude-code-sessions/` | Claude 데스크톱 앱 세션 (읽기만) |
| `defaults` 도메인 `com.engyjoon.claudeoffice` | 앱 설정·창 위치 |

로컬 서버는 `127.0.0.1`에만 열리고 토큰을 검사하므로 회사 네트워크로 나가는 연결은 없습니다.

### 업데이트

메뉴바 아이콘 → 종료한 뒤:

```bash
git pull
```

```bash
make install
```

다시 엽니다. 훅 스크립트가 바뀐 버전이면 **설정 → 연동**에 "다시 설치"가 보입니다.

### 지우기

1. **설정 → 연동 → 제거**로 훅을 뺍니다 (settings.json을 백업한 뒤 Claude Office 훅만 뺌).
2. 로그인 시 실행을 켰다면 끕니다.
3. 앱을 종료하고 지웁니다.
   ```bash
   make uninstall
   ```

## 5. 문제가 생겼을 때

| 증상 | 원인과 해결 |
|---|---|
| `xcodegen이 없습니다: brew install xcodegen` | XcodeGen 미설치. [2단계](#homebrew와-xcodegen) |
| `xcode-select: error: tool 'xcodebuild' requires Xcode` | Xcode가 없거나 다른 곳에 있음. Xcode 설치 후 `sudo xcode-select -s /Applications/Xcode.app` |
| `You have not agreed to the Xcode license agreements` | Xcode를 한 번 실행하거나 `sudo xcodebuild -license accept` |
| 플러그인·구성요소 관련 오류 (`xcodebuild -runFirstLaunch` 안내) | `xcodebuild -runFirstLaunch` 실행 후 다시 빌드 |
| Swift 문법·동시성 오류가 많이 남 | Xcode가 오래됨. 집 맥은 Xcode 26.6(Swift 6.3)에서 빌드함. 최신 Xcode로 올리기. 올릴 수 없으면 오류 메시지를 Claude Code에 보여 주고 고칠 수 있는지 묻기 |
| `make install`에서 `/Applications` 권한 오류 | 관리자 계정이 아님. 관리자에게 요청하거나, `build/DerivedData/Build/Products/Release/Claude Office.app`을 `~/Applications`에 복사해 실행 (로그인 시 실행은 경고가 뜨고 잘 안 될 수 있음) |
| 앱이 열리지 않고 "확인되지 않은 개발자"·"손상됨" 경고 | 직접 빌드한 앱이면 보통 안 생김. 회사 보안 프로그램(CrowdStrike, Jamf Protect, Santa 등)이 막았을 수 있음 → 회사 IT 문의. 옮겨 온 앱이면 [부록](#부록-빌드한-앱을-옮겨-설치하기) |
| 메뉴바 아이콘이 안 보임 | 메뉴바가 꽉 차 가려졌을 수 있음 (특히 노치 있는 맥북). 다른 메뉴바 아이콘을 줄이거나, ⌘ 누른 채 아이콘을 끌어 순서 바꾸기 |
| 사무실에 아무도 안 나타남 | ① 훅 설치 뒤 **새** Claude Code 세션인지 ② 설정 → 연동의 상태 줄(settings.json 등록·스크립트·서버 포트·마지막 이벤트) ③ 테스트 이벤트 ④ `managed-settings.json`에서 훅이 막혔는지 |
| "settings.json을 읽을 수 없어요" | `~/.claude/settings.json`이 올바른 JSON이 아님. 파일을 고친 뒤 다시 설치 |
| 데스크톱 앱 세션만 안 보임 | Claude 데스크톱 앱이 없거나 세션 폴더가 없음. 터미널 `claude` 세션은 훅으로 보임 |

## 부록: 빌드한 앱을 옮겨 설치하기

그 맥에 Xcode를 깔 수 없을 때 쓰는 방법입니다. 업데이트할 때마다 다시 옮겨야 합니다.

**빌드하는 맥에서:**

```bash
make app
```

```bash
ditto -c -k --sequesterRsrc --keepParent "build/DerivedData/Build/Products/Release/Claude Office.app" "build/Claude Office.zip"
```

(`ditto`는 서명이 깨지지 않게 묶어 줍니다.) 앱은 universal이고 최소 macOS 14.0이라 칩에 상관없이 실행됩니다.

**옮기는 방법과 격리 표시:**

| 방법 | 처음 열 때 |
|---|---|
| USB 메모리·외장 디스크에서 Finder로 복사 | 대체로 그냥 열림 |
| AirDrop, 메신저·메일, 브라우저 내려받기 | 막힘 → 아래 "그래도 열기" |
| iCloud Drive 등 동기화 폴더 | 앱마다 다름 (막힌다고 생각하고 준비) |

**설치하는 맥에서:** zip을 풀고 `Claude Office.app`을 `/Applications`로 옮긴 뒤 엽니다. 막히면:

1. 경고 창에서 "완료"를 누릅니다. (macOS 15부터는 **우클릭 → 열기로 넘어가지지 않습니다**.)
2. **시스템 설정 → 개인정보 보호 및 보안** 맨 아래의 "Claude Office이(가) 차단되었습니다" 옆 **그래도 열기** → 암호 입력.
3. 앱을 다시 열고 "열기"를 누릅니다.

"손상되었기 때문에 열 수 없습니다"가 뜨면 격리 표시를 지웁니다. 본인이 만든 앱에만 쓰고, 회사 정책상 허용되는지 확인하세요.

```bash
xattr -dr com.apple.quarantine "/Applications/Claude Office.app"
```

회사가 MDM으로 "그래도 열기"를 막아 두었거나 보안 프로그램이 서명 안 된 앱을 차단하면 이 방법은 쓸 수 없습니다. 그 뒤의 첫 실행은 [4단계](#4-처음-실행-그-맥에서-한-번)와 같습니다.
