import Testing

@testable import AshtynMD

@Suite("Title filenames")
struct TitleFilenameTests {
    @Test("path separators and controls become a safe base name")
    func sanitizesUnsafeCharacters() {
        #expect(TitleFilename.sanitizedBaseName("  Project: / Draft\t\u{0007}  ") == "Project- - Draft")
        #expect(TitleFilename.sanitizedBaseName("...Hidden") == "Hidden")
        #expect(TitleFilename.sanitizedBaseName("name...  ") == "name")
    }

    @Test("empty and dot path components are rejected")
    func rejectsInvalidNames() {
        #expect(TitleFilename.sanitizedBaseName("") == nil)
        #expect(TitleFilename.sanitizedBaseName("   ") == nil)
        #expect(TitleFilename.sanitizedBaseName("...") == nil)
        #expect(TitleFilename.sanitizedBaseName("..") == nil)
    }

    @Test("the result is capped at 120 UTF-8 bytes without splitting a character")
    func capsUTF8Length() {
        let result = TitleFilename.sanitizedBaseName(String(repeating: "é", count: 100))
        #expect(result?.utf8.count == 120)
        #expect(result?.last == "é")
    }

    @Test("collision suffixes continue to represent the managed title")
    func recognizesCollisionSuffixes() {
        #expect(TitleFilename.matches("Groceries.md", title: "Groceries"))
        #expect(TitleFilename.matches("Groceries 2.md", title: "Groceries"))
        #expect(TitleFilename.matches("Groceries 17.md", title: "Groceries"))
        #expect(!TitleFilename.matches("Groceries 1.md", title: "Groceries"))
        #expect(!TitleFilename.matches("Other.md", title: "Groceries"))
    }
}
