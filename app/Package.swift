// swift-tools-version:5.7
import PackageDescription

let package = Package(
    name: "Xone3D",
    platforms: [.macOS(.v11)],
    targets: [
        // libusb, discovered via Homebrew's pkg-config (.pc) file.
        .systemLibrary(
            name: "CLibUSB",
            pkgConfig: "libusb-1.0",
            providers: [.brew(["libusb"])]
        ),
        .executableTarget(
            name: "Xone3D",
            dependencies: ["CLibUSB"]
        ),
    ]
)
