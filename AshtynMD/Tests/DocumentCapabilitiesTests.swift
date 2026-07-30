import Testing
@testable import AshtynMD

@Suite("Document capabilities")
struct DocumentCapabilitiesTests {
    @Test func byteBoundaries() {
        #expect(DocumentCapabilities(byteCount: 0).tier == .full)
        #expect(
            DocumentCapabilities(byteCount: 2 * 1024 * 1024).tier == .full
        )
        #expect(
            DocumentCapabilities(byteCount: 2 * 1024 * 1024 + 1).tier == .large
        )
        #expect(
            DocumentCapabilities(byteCount: 10 * 1024 * 1024).tier == .large
        )
        #expect(
            DocumentCapabilities(byteCount: 10 * 1024 * 1024 + 1).tier
                == .readOnlyLarge
        )
    }

    @Test func largeModeDefersPreviewAndDisablesAI() {
        let value = DocumentCapabilities(byteCount: 3 * 1024 * 1024)
        #expect(value.isEditable)
        #expect(value.previewBehavior == .manual)
        #expect(!value.allowsAICompletion)
    }

    @Test func readOnlyLargeOpensIntoSafeguardedLargeMode() {
        let value = DocumentCapabilities(byteCount: 11 * 1024 * 1024)
        #expect(!value.isEditable)

        let overridden = value.openingAnyway()

        #expect(overridden.tier == .large)
        #expect(overridden.isEditable)
        #expect(overridden.previewBehavior == .manual)
        #expect(!overridden.allowsAICompletion)
    }
}
