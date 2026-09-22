// swift-tools-version: 5.9
// Vitals – monitor systemu dla macOS: Swift + AppKit, pomiary w C++ (SysCore).
import PackageDescription
import Foundation

// A clean checkout can build/test without running the packaging script.
let generatedHelperInfo = Context.packageDirectory + "/Resources/gen/Helper-Info.plist"
let helperInfo = FileManager.default.fileExists(atPath: generatedHelperInfo)
    ? generatedHelperInfo : Context.packageDirectory + "/Resources/Helper-Info.development.plist"

let package = Package(
    name: "Vitals",
    platforms: [.macOS(.v13)],
    targets: [
        // Warstwa pomiarowa: libproc, Mach, sysctl, IOKit. Czyste C API dla Swifta.
        .target(
            name: "SysCore",
            path: "Sources/SysCore",
            publicHeadersPath: "include",
            linkerSettings: [
                .linkedFramework("IOKit"),
                .linkedFramework("CoreFoundation"),
            ]
        ),
        // Wspólny protokół XPC aplikacja ↔ pomocnik
        .target(name: "HelperKit", path: "Sources/HelperKit"),
        // Pomocnik uprzywilejowany (LaunchDaemon rejestrowany przez SMAppService)
        .executableTarget(
            name: "VitalsHelper",
            dependencies: ["SysCore", "HelperKit"],
            path: "Sources/Helper",
            linkerSettings: [
                .linkedFramework("IOKit"),
                // osadzone Info.plist i launchd.plist wymagane przez SMJobBless
                .unsafeFlags(["-Xlinker", "-sectcreate", "-Xlinker", "__TEXT", "-Xlinker", "__info_plist", "-Xlinker", helperInfo,
                              "-Xlinker", "-sectcreate", "-Xlinker", "__TEXT", "-Xlinker", "__launchd_plist", "-Xlinker", Context.packageDirectory + "/Resources/Helper-Launchd.plist"]),
            ]
        ),
        // Aplikacja AppKit
        .executableTarget(
            name: "Vitals",
            dependencies: ["SysCore", "HelperKit"],
            path: "Sources/App",
            swiftSettings: [.unsafeFlags(["-parse-as-library"])],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("QuartzCore"),
                .linkedFramework("ServiceManagement"),
                .linkedFramework("VideoToolbox"),
                .linkedFramework("CoreMedia"),
            ]
        ),
        .testTarget(name: "VitalsTests", dependencies: ["Vitals", "HelperKit", "SysCore"], path: "Tests/VitalsTests"),
    ],
    swiftLanguageVersions: [.v5],
    cxxLanguageStandard: .cxx17
)
