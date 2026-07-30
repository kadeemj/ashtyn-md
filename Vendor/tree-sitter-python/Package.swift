// swift-tools-version:5.9
// Vendored from tree-sitter/tree-sitter-python v0.25.0 (MIT). Upstream's
// manifest probes for src/scanner.c with a CWD-relative path, which drops the
// external scanner in Xcode builds. This copy lists sources statically.
import PackageDescription

let package = Package(
    name: "TreeSitterPython",
    products: [
        .library(name: "TreeSitterPython", targets: ["TreeSitterPython"]),
    ],
    targets: [
        .target(
            name: "TreeSitterPython",
            path: ".",
            exclude: ["LICENSE"],
            sources: ["src/parser.c", "src/scanner.c"],
            resources: [.copy("queries")],
            publicHeadersPath: "bindings/swift",
            cSettings: [.headerSearchPath("src")]
        ),
    ],
    cLanguageStandard: .c11
)
