// swift-tools-version: 5.9
import PackageDescription

let package = Package(
  name: "MenuCue",
  defaultLocalization: "en",
  platforms: [.macOS(.v14)],
  products: [
    .executable(name: "MenuCue", targets: ["MenuCue"]),
    .executable(name: "MenuCueHelper", targets: ["MenuCueHelper"]),
  ],
  targets: [
    .target(
      name: "MenuCueHelperProtocol",
      path: "Sources/MenuCueHelperProtocol"
    ),
    .executableTarget(
      name: "MenuCueHelper",
      dependencies: ["MenuCueHelperProtocol"],
      path: "Sources/MenuCueHelper",
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
      name: "MenuCue",
      dependencies: [
        "MenuCueHelperProtocol",
        "Sparkle",
      ],
      path: "Sources/MenuCue",
      resources: [.process("Resources")],
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
      name: "MenuCueTests",
      dependencies: [
        "MenuCue",
        "MenuCueHelperProtocol",
        "Sparkle",
      ],
      path: "Tests/MenuCueTests"
    ),
  ]
)
