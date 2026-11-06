// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "ClaudeOffice",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "OfficeCore", targets: ["OfficeCore"]),
        .executable(name: "office-sim", targets: ["office-sim"]),
    ],
    targets: [
        // 순수 Swift 코어: 훅 파싱, 상태, 연출 결정, 대화, 효과음. Linux에서도 빌드·테스트합니다.
        .target(
            name: "OfficeCore",
            resources: [.process("Resources")]
        ),
        // 시나리오를 엔진에 흘려 연출 타임라인을 출력하고, 효과음을 WAV로 렌더링하는 개발용 CLI
        .executableTarget(
            name: "office-sim",
            dependencies: ["OfficeCore"]
        ),
        .testTarget(
            name: "OfficeCoreTests",
            dependencies: ["OfficeCore"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
