// swift-tools-version: 5.9

// 在 iPad 的 Swift Playgrounds 或 Mac 的 Xcode 中打开本文件夹即可运行。
// 没有 AppleProductTypes 的环境（例如命令行 swift build）会编译成普通可执行文件，用于检查代码。

import PackageDescription

#if canImport(AppleProductTypes)
import AppleProductTypes
#endif

#if canImport(AppleProductTypes)
let products: [Product] = [
    .iOSApplication(
        name: "Stepwise",
        targets: ["AppModule"],
        bundleIdentifier: "com.lswill2007.stepwise",
        teamIdentifier: "",
        displayVersion: "1.0",
        bundleVersion: "1",
        appIcon: .placeholder(icon: .leaf),
        accentColor: .presetColor(.indigo),
        supportedDeviceFamilies: [
            .pad,
            .phone
        ],
        supportedInterfaceOrientations: [
            .portrait,
            .landscapeRight,
            .landscapeLeft,
            .portraitUpsideDown(.when(deviceFamilies: [.pad]))
        ],
        capabilities: [
            .camera(purposeString: "用于扫描纸质题目")
        ],
        appCategory: .education
    )
]
#else
let products: [Product] = []
#endif

let package = Package(
    name: "Stepwise",
    platforms: [
        .iOS("17.0"),
        .macOS("14.0")
    ],
    products: products,
    targets: [
        .executableTarget(
            name: "AppModule",
            path: "Sources/App"
        )
    ]
)
