# Claude Office 개발 명령
SWIFT ?= swift
APP_NAME := Claude Office.app
DERIVED := build/DerivedData
APP_PATH := $(DERIVED)/Build/Products/Release/$(APP_NAME)

# xcode-select가 Command Line Tools를 가리켜도 Xcode.app이 있으면 그것을 사용
ifeq ($(origin DEVELOPER_DIR),undefined)
  ifneq ($(findstring CommandLineTools,$(shell xcode-select -p 2>/dev/null)),)
    ifneq ($(wildcard /Applications/Xcode.app/Contents/Developer),)
      export DEVELOPER_DIR := /Applications/Xcode.app/Contents/Developer
    endif
  endif
endif

.PHONY: build test demo sounds snapshot serve replay notify-demo bootstrap app run install uninstall clean

## ---- 코어 (macOS·Linux) ----

build:
	$(SWIFT) build

## OfficeCore·OfficeServer 단위 테스트
test:
	$(SWIFT) test

## 위임 시나리오를 엔진에 흘려 연출 타임라인 출력
demo:
	$(SWIFT) run -q office-sim run Scenarios/delegation.jsonl

## 효과음을 build/sounds/*.wav로 렌더링
sounds:
	$(SWIFT) run -q office-sim sounds build/sounds

## 사무실 장면을 build/snapshots/*.svg로 (맥 없이 그림 확인, 사무실 1140×708·둘레 여백 20·배율 1)
##   위임: 2.6초 종이비행기 · 11초 자기 책상에서 읽기 · 20초 외침 풍선 · 52.2초 보고 · 61.5초 응답 완료 · 128초 휴게 공간
##   혼잡(행 배치): 30초 넘친 서브 +2 · 52초 가운데 서브 퇴근 후 끝 서브가 들어옴(+1) · 80초 셋째 행이 넷째 메인으로
snapshot:
	$(SWIFT) run -q office-sim snapshot Scenarios/delegation.jsonl --at 2.6,11,20,52.2,61.5,128 --out build/snapshots
	$(SWIFT) run -q office-sim snapshot Scenarios/floor.jsonl --at 30,52,80 --out build/snapshots

## 맥 앱 없이 훅 서버+엔진만 실행 (직원 목록만 출력)
serve:
	$(SWIFT) run -q office-sim serve --roster-only

## 실행 중인 앱(또는 serve)으로 관찰 시나리오를 2배속 전송
replay:
	$(SWIFT) run -q office-sim replay Scenarios/m0-observed.jsonl --speed 2

## 실행 중인 앱으로 승인 대기 알림 시나리오를 1배속 전송 (40초 대기 → 풀림 → 완료 → 퇴근, 약 1분)
notify-demo:
	$(SWIFT) run -q office-sim replay Scenarios/notify.jsonl

## ---- macOS 앱 (Xcode 필요) ----

## XcodeGen으로 App/ClaudeOffice.xcodeproj 생성
bootstrap:
	@command -v xcodegen >/dev/null || { echo "xcodegen이 없습니다: brew install xcodegen"; exit 1; }
	cd App && xcodegen generate

## Release 빌드 (로컬 서명)
app: bootstrap
	set -o pipefail; xcodebuild -project App/ClaudeOffice.xcodeproj -scheme ClaudeOffice -configuration Release \
		-derivedDataPath $(DERIVED) build | tail -n 20

## 빌드한 앱 실행
run: app
	open "$(APP_PATH)"

## /Applications에 복사
install: app
	rm -rf "/Applications/$(APP_NAME)"
	cp -R "$(APP_PATH)" /Applications/
	@echo "/Applications/$(APP_NAME) 에 설치했습니다."

uninstall:
	rm -rf "/Applications/$(APP_NAME)"

clean:
	rm -rf .build build App/ClaudeOffice.xcodeproj App/Generated
