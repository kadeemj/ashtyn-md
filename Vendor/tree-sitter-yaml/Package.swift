// swift-tools-version:5.9
// Vendored from tree-sitter-grammars/tree-sitter-yaml v0.7.2 (MIT).
// Upstream's manifest probes for src/scanner.c with a CWD-relative path,
// which silently drops the external scanner when built through Xcode and
// breaks linking. This copy lists the sources statically.
import PackageDescription

let package = Package(
    name: "TreeSitterYAML",
    products: [
        .library(name: "TreeSitterYAML", targets: ["TreeSitterYAML"]),
    ],
    targets: [
        .target(
            name: "TreeSitterYAML",
            path: ".",
            exclude: ["LICENSE", "src/grammar.json", "src/node-types.json"],
            sources: ["src/parser.c", "src/scanner.c"],
            resources: [
                .copy("queries")
            ],
            publicHeadersPath: "bindings/swift",
            cSettings: [.headerSearchPath("src")]
        ),
    ],
    cLanguageStandard: .c11
)
