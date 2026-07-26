// swift-tools-version: 5.9
import PackageDescription

let package = Package(
  name: "TouchMacer",
  platforms: [.macOS(.v14)],
  products: [
    .executable(name: "TouchMacer", targets: ["TouchMacer"]),
    .executable(name: "TouchMacerHelper", targets: ["TouchMacerHelper"]),
  ],
  targets: [
    .target(
      name: "TouchMacerHelperProtocol",
      path: "Sources/TouchMacerHelperProtocol"
    ),
    .executableTarget(
      name: "TouchMacerHelper",
      dependencies: ["TouchMacerHelperProtocol"],
      path: "Sources/TouchMacerHelper",
      linkerSettings: [
        .linkedFramework("Security")
      ]
    ),
    .binaryTarget(
      name: "Sparkle",
      url: "https://github.com/sparkle-project/Sparkle/releases/download/2.9.4/Sparkle-for-Swift-Package-Manager.zip",
      checksum: "cb6fdbdc8884f15d62a616e79face92b08322410fd2d425edc6596ccbf4ba3b0"
    ),
    .executableTarget(
      name: "TouchMacer",
      dependencies: [
        "TouchMacerHelperProtocol",
        "Sparkle",
      ],
      path: "Sources/TouchMacer",
      linkerSettings: [
        .linkedFramework("AppKit"),
        .linkedFramework("ApplicationServices"),
        .linkedFramework("EventKit"),
        .linkedFramework("ServiceManagement"),
        .linkedFramework("Security"),
        .linkedFramework("SwiftUI"),
        .unsafeFlags([
          "-Xlinker", "-rpath",
          "-Xlinker", "@executable_path/../Frameworks",
        ]),
      ]
    ),
    .testTarget(
      name: "TouchMacerTests",
      dependencies: [
        "TouchMacer",
        "TouchMacerHelperProtocol",
        "Sparkle",
      ],
      path: "Tests/TouchMacerTests"
    ),
  ]
)
