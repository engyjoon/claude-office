# Claude Office

Claude Code 세션과 서브에이전트가 일하는 모습을 아기자기한 가상 사무실로 보여주는 macOS 앱입니다.
세션은 팀장으로, 서브에이전트는 팀원으로 출근하고, 말풍선과 표정과 제스처로 지금 무슨 일을 하는지 알려줍니다.

- 설계서: [docs/DESIGN.md](docs/DESIGN.md)
- 스타일 미리보기: [docs/preview/index.html](docs/preview/index.html)
- 훅 페이로드 수집 안내 (M0): [docs/M0-capture.md](docs/M0-capture.md)
- 맥에서 빌드하고 확인하기 (M2): [docs/M2-build.md](docs/M2-build.md)

## 진행 상황

| 단계 | 상태 |
|---|---|
| M0 준비: 실제 훅 수집 | 완료. Claude Code 2.1.318, 98건 (설계서 §4.1) |
| **M1 코어** (`OfficeCore`) | **완료**. 훅 파서, 사무실 상태, 연출 엔진, 대사, 효과음 합성 |
| M2 앱 뼈대 (메뉴바, 로컬 서버, 훅 설치) | 완료. 맥에서 실제 Claude Code 세션 확인 |
| **M3 사무실 화면** (SpriteKit) | **작성 완료, 맥 확인 대기**. 배치·길찾기·무대·그림 데이터는 Linux 테스트와 SVG 스냅숏으로 확인 ([장면 예시](docs/m3/)) |
| M4~M6 표현(말풍선·효과음), 미니 사무실·알림, 다듬기 | 예정 |

## 개발

Swift 6 툴체인이 필요합니다. 코어는 Linux에서도 빌드하고 테스트할 수 있습니다.

```bash
make test
```

```bash
make demo
```

`make demo`는 `Scenarios/delegation.jsonl`(출근 → 위임 → 승인 대기 → 보고 → 휴식 → 퇴근)을 엔진에 넣고, 씬에 내려갈 지시를 시간 순서대로 출력합니다. `Scenarios/m0-observed.jsonl`은 실제 수집에서 관찰한 서브에이전트 패턴을 재현합니다.

```bash
make sounds
```

`make sounds`는 효과음을 `build/sounds/*.wav`로 저장하고, `make snapshot`은 사무실 장면을 `build/snapshots/*.svg`로 그립니다 (맥 없이 그림 확인).

맥 앱은 Xcode와 XcodeGen이 필요합니다 ([docs/M2-build.md](docs/M2-build.md)).

```bash
make run
```

`make serve`는 맥 앱 없이 훅 서버와 엔진만 실행하고(Linux 포함), `make replay`는 실행 중인 앱이나 serve로 시나리오를 보냅니다.

## 구조

```
Sources/OfficeCore/   순수 Swift 코어 (훅 → 이벤트 → 사무실 상태 → 연출 지시, 효과음, 메뉴 목록)
Sources/OfficeServer/ 로컬 훅 서버(BSD 소켓), 훅 스크립트, 훅 설치기 (macOS·Linux)
Sources/OfficeStage/  사무실 배치, 길찾기, 무대(연출 지시 실행), 캐릭터·가구 그림 데이터, SVG 렌더러
Sources/office-sim/   개발용 CLI (연출 타임라인, 효과음 WAV, 헤드리스 serve, replay)
App/                  macOS 메뉴바 앱 (SwiftUI, XcodeGen project.yml)
Tests/OfficeCoreTests 단위 테스트와 훅 픽스처
Scenarios/            office-sim 시나리오
scripts/              M0 훅 수집 도구
docs/                 설계서, 미리보기, 안내서
```
