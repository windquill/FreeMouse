// swift-tools-version: 5.9
import PackageDescription
let package = Package(name: "FreeMouse", platforms: [.macOS("15.0")], products: [.executable(name: "FreeMouse", targets: ["FreeMouse"])], targets: [.executableTarget(name: "FreeMouse"), .testTarget(name: "FreeMouseTests", dependencies: ["FreeMouse"], resources: [.copy("Fixtures/ScrollNative121")])])
