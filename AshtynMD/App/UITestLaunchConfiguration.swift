#if DEBUG
import Foundation

@MainActor
struct UITestLaunchConfiguration {
    let isEnabled: Bool
    let resetsLibrary: Bool
    let showsOnboarding: Bool
    let opensStandalone: Bool
    let enablesAutomaticAI: Bool

    private static let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("AshtynMD-UITests", isDirectory: true)
    private static var hasResetLibrary = false

    static var current: UITestLaunchConfiguration {
        let arguments = Set(ProcessInfo.processInfo.arguments)
        return UITestLaunchConfiguration(
            isEnabled: arguments.contains("-ui-testing"),
            resetsLibrary: arguments.contains("-ui-test-reset"),
            showsOnboarding: arguments.contains("-ui-test-show-onboarding"),
            opensStandalone: arguments.contains("-ui-test-standalone"),
            enablesAutomaticAI: arguments.contains("-ui-test-automatic-ai")
        )
    }

    static func prepareFixtureLibrary() throws -> URL {
        let library = root.appendingPathComponent("Library", isDirectory: true)
        if current.resetsLibrary && !hasResetLibrary {
            hasResetLibrary = true
            let metadata = AppSupportPaths.libraryDirectory(forRoot: library)
            if FileManager.default.fileExists(atPath: metadata.path) {
                try FileManager.default.removeItem(at: metadata)
            }
            if FileManager.default.fileExists(atPath: root.path) {
                try FileManager.default.removeItem(at: root)
            }
        }
        if !FileManager.default.fileExists(atPath: library.path) {
            try FileManager.default.createDirectory(
                at: library.appendingPathComponent("Code", isDirectory: true),
                withIntermediateDirectories: true
            )
            try FileManager.default.createDirectory(
                at: library.appendingPathComponent("Images", isDirectory: true),
                withIntermediateDirectories: true
            )
            try Data("# Fixture Note\n\nSearchable alpha content.\n".utf8)
                .write(to: library.appendingPathComponent("Fixture Note.md"))
            try Data("let fixtureValue = 42\n".utf8)
                .write(to: library.appendingPathComponent("Code/sample.swift"))

            // Added rather than folded into Fixture Note.md, which existing
            // assertions depend on.
            try Data(
                """
                Weekly Review

                Wrapping up the week #work/alpha and #reading

                - [ ] draft the summary
                - [x] collect metrics

                See also [[Fixture Note]] for context.
                """.utf8
            ).write(to: library.appendingPathComponent("Tagged Note.md"))

            try FileManager.default.createDirectory(
                at: library.appendingPathComponent(InboxFolder.name, isDirectory: true),
                withIntermediateDirectories: true
            )
            try Data("Captured Note\n\nstraight into the inbox\n".utf8)
                .write(
                    to: library
                        .appendingPathComponent(InboxFolder.name)
                        .appendingPathComponent("Captured Note.md")
                )

            let largeFile = library.appendingPathComponent("Large.md")
            _ = FileManager.default.createFile(atPath: largeFile.path, contents: nil)
            let handle = try FileHandle(forWritingTo: largeFile)
            try handle.write(contentsOf: Data("# Large Fixture\n".utf8))
            try handle.truncate(atOffset: 11 * 1024 * 1024)
            try handle.close()

            let pixel = Data(base64Encoded:
                "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="
            )!
            try pixel.write(to: library.appendingPathComponent("Images/pixel.png"))
        }
        return library
    }

    static func standaloneFixtureURL() throws -> URL {
        _ = try prepareFixtureLibrary()
        let url = root.appendingPathComponent("Standalone.md")
        if !FileManager.default.fileExists(atPath: url.path) {
            try Data("# Standalone Fixture\n".utf8).write(to: url)
        }
        return url
    }

}

struct UITestAIProvider: AICompletionProvider {
    let id = AIProviderID.ollama

    func availableModels() async throws -> [AIModel] {
        [AIModel(id: "ui-test", displayName: "UI Test")]
    }

    func validateConfiguration() async throws {}

    func complete(
        _ request: AICompletionRequest
    ) -> AsyncThrowingStream<AICompletionEvent, Error> {
        return AsyncThrowingStream<AICompletionEvent, Error> { continuation in
            continuation.yield(.textDelta("fixtureSuggestion"))
            continuation.yield(.completed(nil))
            continuation.finish()
        }
    }
}
#endif
