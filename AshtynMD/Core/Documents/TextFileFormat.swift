import Foundation

/// Line-ending style of a file on disk. In memory Ashtyn MD always works with
/// `\n`; the original style is reapplied on save.
enum LineEnding: String, Codable, Sendable {
    case lf
    case crlf

    /// Majority style of the given text; LF wins ties and empty documents.
    static func detect(in text: String) -> LineEnding {
        var lf = 0
        var crlf = 0
        var previousWasCR = false
        for scalar in text.unicodeScalars {
            if scalar == "\n" {
                if previousWasCR { crlf += 1 } else { lf += 1 }
                previousWasCR = false
            } else {
                previousWasCR = scalar == "\r"
            }
        }
        return crlf > lf ? .crlf : .lf
    }

    /// Normalizes any mix of CRLF/CR/LF to plain `\n`.
    static func normalizeToLF(_ text: String) -> String {
        // Check scalars, not Characters: "\r\n" is one grapheme cluster, so
        // `text.contains("\r")` would miss CRLF entirely.
        guard text.unicodeScalars.contains("\r") else { return text }
        return text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
    }

    /// Converts LF-normalized text back to this style for writing.
    func denormalize(_ normalized: String) -> String {
        switch self {
        case .lf: return normalized
        case .crlf: return normalized.replacingOccurrences(of: "\n", with: "\r\n")
        }
    }
}

/// Encoding of a file on disk, including whether it carried a BOM, so a save
/// reproduces the exact byte-level framing the file arrived with.
enum TextFileEncoding: Codable, Sendable, Equatable {
    case utf8(bom: Bool)
    case utf16LittleEndian
    case utf16BigEndian
    /// Fallback for non-UTF textual data; preserved on save.
    case isoLatin1

    var displayName: String {
        switch self {
        case .utf8(bom: false): return "UTF-8"
        case .utf8(bom: true): return "UTF-8 with BOM"
        case .utf16LittleEndian: return "UTF-16 LE"
        case .utf16BigEndian: return "UTF-16 BE"
        case .isoLatin1: return "ISO Latin 1"
        }
    }

    /// Decodes file data, honoring BOMs first, then trying UTF-8, then
    /// falling back to Latin-1 (which cannot fail) so unknown textual files
    /// still open as plain text.
    static func decode(_ data: Data) -> (text: String, encoding: TextFileEncoding) {
        let bytes = [UInt8](data.prefix(3))
        if bytes.count >= 3, bytes[0] == 0xEF, bytes[1] == 0xBB, bytes[2] == 0xBF {
            let body = data.dropFirst(3)
            if let text = String(data: body, encoding: .utf8) {
                return (text, .utf8(bom: true))
            }
        }
        if bytes.count >= 2, bytes[0] == 0xFF, bytes[1] == 0xFE {
            if let text = String(data: data.dropFirst(2), encoding: .utf16LittleEndian) {
                return (text, .utf16LittleEndian)
            }
        }
        if bytes.count >= 2, bytes[0] == 0xFE, bytes[1] == 0xFF {
            if let text = String(data: data.dropFirst(2), encoding: .utf16BigEndian) {
                return (text, .utf16BigEndian)
            }
        }
        if let text = String(data: data, encoding: .utf8) {
            return (text, .utf8(bom: false))
        }
        let latin = String(data: data, encoding: .isoLatin1) ?? ""
        return (latin, .isoLatin1)
    }

    /// Encodes text (already denormalized to its target line endings) back to
    /// bytes, reattaching the BOM the file originally had.
    func encode(_ text: String) throws -> Data {
        switch self {
        case .utf8(let bom):
            var data = bom ? Data([0xEF, 0xBB, 0xBF]) : Data()
            data.append(Data(text.utf8))
            return data
        case .utf16LittleEndian:
            var data = Data([0xFF, 0xFE])
            guard let body = text.data(using: .utf16LittleEndian) else {
                throw TextFileError.unencodableContent(displayName)
            }
            data.append(body)
            return data
        case .utf16BigEndian:
            var data = Data([0xFE, 0xFF])
            guard let body = text.data(using: .utf16BigEndian) else {
                throw TextFileError.unencodableContent(displayName)
            }
            data.append(body)
            return data
        case .isoLatin1:
            guard let data = text.data(using: .isoLatin1) else {
                throw TextFileError.unencodableContent(displayName)
            }
            return data
        }
    }
}

enum TextFileError: Error, LocalizedError {
    case unencodableContent(String)

    var errorDescription: String? {
        switch self {
        case .unencodableContent(let encoding):
            return "The document contains characters that cannot be saved as \(encoding)."
        }
    }
}

/// A text file as loaded from disk: LF-normalized content plus everything
/// needed to write it back byte-faithfully.
struct LoadedTextFile: Sendable {
    var text: String
    var encoding: TextFileEncoding
    var lineEnding: LineEnding

    static func load(from url: URL) throws -> LoadedTextFile {
        let data = try Data(contentsOf: url)
        let (raw, encoding) = TextFileEncoding.decode(data)
        let lineEnding = LineEnding.detect(in: raw)
        return LoadedTextFile(
            text: LineEnding.normalizeToLF(raw),
            encoding: encoding,
            lineEnding: lineEnding
        )
    }

    /// Bytes to write for the current content, with original line endings,
    /// encoding, and BOM restored.
    func encodedData() throws -> Data {
        try encoding.encode(lineEnding.denormalize(text))
    }
}
