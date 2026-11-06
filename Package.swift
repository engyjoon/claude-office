// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "ClaudeOffice",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "OfficeCore", targets: ["OfficeCore"]),
        .library(name: "OfficeServer", targets: ["OfficeServer"]),
        .executable(name: "office-sim", targets: ["office-sim"]),
    ],
    targets: [
        // 순수 Swift 코어: 훅 파싱, 상태, 연출 결정, 대화, 효과음. Linux에서도 빌드·테스트합니다.
        .target(
            name: "OfficeCore",
            resources: [.process("Resources")]
        ),
        // 로컬 훅 서버(BSD 소켓), 엔드포인트 파일, 훅 설치기. macOS와 Linux 모두에서 동작합니다.
        .target(
            name: "OfficeServer",
            dependencies: ["OfficeCore"],
            resources: [.copy("Resources/claude-office.sh")]
        ),
        // 개발용 CLI: 연출 타임라인(run), 효과음 WAV(sounds), 헤드리스 서버(serve), 앱으로 재생(replay)
        .executableTarget(
            name: "office-sim",
            dependencies: ["OfficeCore", "OfficeServer"]
        ),
        .testTarget(
            name: "OfficeCoreTests",
            dependencies: ["OfficeCore"],
            resources: [.copy("Fixtures")]
        ),
        .testTarget(
            name: "OfficeServerTests",
            dependencies: ["OfficeServer", "OfficeCore"]
        ),
    ]
)
