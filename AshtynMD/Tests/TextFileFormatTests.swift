import Foundation
import Testing
@testable import AshtynMD

@Suite("Line endings")
struct LineEndingTests {
    @Test func detectsLF() {
        #expect(LineEnding.detect(in: "a\nb\nc\n") == .lf)
    }

    @Test func detectsCRLF() {
        #expect(LineEnding.detect(in: "a\r\nb\r\nc\r\n") == .crlf)
    }

    @Test func mixedMajorityWins() {
        #expect(LineEnding.detect(in: "a\r\nb\r\nc\n") == .crlf)
        #expect(LineEnding.detect(in: "a\nb\nc\r\n") == .lf)
    }

    @Test func emptyAndSingleLineDefaultToLF() {
        #expect(LineEnding.detect(in: "") == .lf)
        #expect(LineEnding.detect(in: "no newline") == .lf)
    }

    @Test func normalizesCRLFAndBareCR() {
        #expect(LineEnding.normalizeToLF("a\r\nb\rc\n") == "a\nb\nc\n")
    }

    @Test func denormalizeRoundTrip() {
        let original = "one\r\ntwo\r\nthree"
        let normalized = LineEnding.normalizeToLF(original)
        #expect(normalized == "one\ntwo\nthree")
        #expect(LineEnding.crlf.denormalize(normalized) == original)
        #expect(LineEnding.lf.denormalize(normalized) == normalized)
    }
}

@Suite("Text encodings")
struct TextEncodingTests {
    @Test func utf8WithoutBOM() throws {
        let text = "héllo wörld 🌍"
        let data = Data(text.utf8)
        let decoded = TextFileEncoding.decode(data)
        #expect(decoded.text == text)
        #expect(decoded.encoding == .utf8(bom: false))
        #expect(try decoded.encoding.encode(decoded.text) == data)
    }

    @Test func utf8WithBOMRoundTrip() throws {
        let text = "bom test"
        var data = Data([0xEF, 0xBB, 0xBF])
        data.append(Data(text.utf8))
        let decoded = TextFileEncoding.decode(data)
        #expect(decoded.text == text)
        #expect(decoded.encoding == .utf8(bom: true))
        #expect(try decoded.encoding.encode(decoded.text) == data)
    }

    @Test func utf16LittleEndianRoundTrip() throws {
        let text = "utf16 ✓"
        var data = Data([0xFF, 0xFE])
        data.append(text.data(using: .utf16LittleEndian)!)
        let decoded = TextFileEncoding.decode(data)
        #expect(decoded.text == text)
        #expect(decoded.encoding == .utf16LittleEndian)
        #expect(try decoded.encoding.encode(decoded.text) == data)
    }

    @Test func utf16BigEndianRoundTrip() throws {
        let text = "utf16 be ✓"
        var data = Data([0xFE, 0xFF])
        data.append(text.data(using: .utf16BigEndian)!)
        let decoded = TextFileEncoding.decode(data)
        #expect(decoded.text == text)
        #expect(decoded.encoding == .utf16BigEndian)
        #expect(try decoded.encoding.encode(decoded.text) == data)
    }

    @Test func invalidUTF8FallsBackToLatin1() {
        // 0xE9 alone is invalid UTF-8 but is "é" in Latin-1.
        let data = Data([0x63, 0x61, 0x66, 0xE9])
        let decoded = TextFileEncoding.decode(data)
        #expect(decoded.text == "café")
        #expect(decoded.encoding == .isoLatin1)
    }

    @Test func loadedFilePreservesCRLFOnEncode() throws {
        let file = LoadedTextFile(
            text: "a\nb\nc", encoding: .utf8(bom: false), lineEnding: .crlf
        )
        let data = try file.encodedData()
        #expect(String(data: data, encoding: .utf8) == "a\r\nb\r\nc")
    }
}
