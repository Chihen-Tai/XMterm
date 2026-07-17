// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "XMterm",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "XMterm", targets: ["XMtermApp"]),
        .library(name: "XMtermCore", targets: ["XMtermCore"]),
        .library(name: "XMtermRemote", targets: ["XMtermRemote"])
    ],
    dependencies: [
        .package(
            url: "https://github.com/migueldeicaza/SwiftTerm.git",
            exact: "1.14.0"
        )
    ],
    targets: [
        .target(name: "XMtermCore"),
        .target(
            name: "CXMtermPTY",
            publicHeadersPath: "include"
        ),
        .target(
            name: "XMtermTerminal",
            dependencies: [
                "XMtermCore",
                "CXMtermPTY",
                .product(name: "SwiftTerm", package: "SwiftTerm")
            ]
        ),
        .target(
            name: "XMtermRemote",
            dependencies: ["XMtermCore"]
        ),
        .executableTarget(
            name: "XMtermApp",
            dependencies: ["XMtermCore", "XMtermRemote", "XMtermTerminal"]
        ),
        .testTarget(
            name: "XMtermCoreTests",
            dependencies: ["XMtermCore"]
        ),
        .testTarget(
            name: "XMtermTerminalTests",
            dependencies: ["XMtermTerminal", "XMtermCore"]
        ),
        .testTarget(
            name: "XMtermRemoteTests",
            dependencies: ["XMtermRemote"]
        ),
        .testTarget(
            name: "XMtermAppTests",
            dependencies: ["XMtermApp", "XMtermRemote"]
        )
    ]
)
