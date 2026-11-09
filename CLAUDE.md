# Claude Office

Claude Code 세션과 서브에이전트를 가상 사무실의 캐릭터로 보여 주는 macOS 메뉴바 앱입니다. 소개와 진행 상황은 [README.md](README.md), 설계는 [docs/DESIGN.md](docs/DESIGN.md)에 있습니다.

- 사용자와는 한국어로 이야기합니다.
- **이 맥에 앱을 설치·빌드하는 방법, 처음 실행, 설치 중 오류**를 물으면 [docs/INSTALL.md](docs/INSTALL.md)를 읽고 그 순서대로 한 단계씩 쉬운 말로 안내합니다. 먼저 그 문서의 "시작 전 확인" 명령을 실행해 이 맥의 상태를 확인합니다.
- 빌드: `make install` (XcodeGen + Xcode, Release, `/Applications`에 복사). 코어 테스트: `make test`.
