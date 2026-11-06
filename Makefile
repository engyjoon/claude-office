# Claude Office 개발 명령
SWIFT ?= swift

.PHONY: build test demo sounds clean

build:
	$(SWIFT) build

## OfficeCore 단위 테스트 (Linux와 macOS 모두)
test:
	$(SWIFT) test

## 위임 시나리오를 엔진에 흘려 연출 타임라인 출력
demo:
	$(SWIFT) run -q office-sim run Scenarios/delegation.jsonl

## 효과음을 build/sounds/*.wav로 렌더링
sounds:
	$(SWIFT) run -q office-sim sounds build/sounds

clean:
	rm -rf .build build
